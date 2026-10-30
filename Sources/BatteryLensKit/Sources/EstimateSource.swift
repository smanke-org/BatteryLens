import BatteryLensShared
import Foundation
import IOKit

/// Estimated levels for devices that never report one (the Matias keyboard), once
/// they've been marked charged. Counts their use with `UsageMonitor`, keeps this Mac's
/// `UsageLog`, and reads the other Macs' logs, so use on any of your Macs counts.
///
/// Logs live in iCloud Drive/BatteryLens/Usage, one file per Mac so iCloud never has
/// two writers to reconcile; with iCloud Drive off they stay in Application Support.
public final class EstimateSource: BatterySource {
    public let kind = SourceKind.estimate
    public private(set) var status = "not started"
    public var onReadings: (([BatteryReading]) -> Void)?
    /// False for a device whose "Report this device" is off: no counting, no estimate.
    public var isReporting: (String) -> Bool = { _ in true }
    /// The name and kind to give an estimate, so a device known only by it keeps them.
    public var describe: (String) -> (name: String, kind: DeviceKind)? = { _ in nil }

    public private(set) var ownLog: UsageLog
    private var others: [String: UsageLog] = [:]
    private let usage = UsageMonitor()
    private let folder: URL?
    private var dirty = false
    private var lastSave = Date.distantPast
    private var lastRead = Date.distantPast
    private var timer: Timer?

    static let usageRetention: TimeInterval = 365 * 24 * 3600

    /// `folder` nil keeps everything in memory (tests).
    public init(folder: URL? = EstimateSource.defaultFolder, macID: String = EstimateSource.macID,
                macName: String = Host.current().localizedName ?? "Mac") {
        self.folder = folder
        ownLog = UsageLog(macID: macID, macName: macName)
        if let folder, let saved = Self.read(folder.appendingPathComponent("\(macID).json")) {
            ownLog = saved
            ownLog.macName = macName
        }
    }

    /// iCloud Drive/BatteryLens/Usage, or Application Support when iCloud Drive is off.
    /// `BATTERYLENS_SYNC_FOLDER` redirects it for testing a copy of the app.
    public static var defaultFolder: URL? {
        if let override = ProcessInfo.processInfo.environment["BATTERYLENS_SYNC_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: cloudDocs.path) {
            return cloudDocs.appendingPathComponent("BatteryLens/Usage", isDirectory: true)
        }
        return DeviceStore.defaultURL?.deletingLastPathComponent().appendingPathComponent("Usage", isDirectory: true)
    }

    public var isSyncing: Bool { folder?.path.contains("com~apple~CloudDocs") == true }

    /// This Mac's hardware UUID, the same in every app and across reinstalls.
    public static let macID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? UUID().uuidString
    }()

    // MARK: - BatterySource

    public func start() {
        usage.onActiveMinute = { [weak self] key, date in
            guard let self, self.isReporting(key) else { return }
            self.ownLog.addMinute(key, at: date)
            self.dirty = true
            self.emit()
        }
        usage.start()
        readOthers()
        updateTracking()
        emit()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    public func refresh() {
        usage.refresh()
        readOthers()
        updateTracking()
        emit()
    }

    private func tick() {
        if Date().timeIntervalSince(lastRead) > 300 { readOthers() }
        if dirty, Date().timeIntervalSince(lastSave) > 300 { save() }
        updateTracking()
        emit()
    }

    // MARK: - Estimates

    public var logs: [UsageLog] { [ownLog] + Array(others.values) }

    /// Devices with an estimate: every one marked charged on any Mac.
    public var trackedKeys: Set<String> { Set(logs.flatMap { $0.charges.map(\.device) }) }

    public func estimate(for key: String, now: Date = Date()) -> Estimator.Estimate? {
        Estimator.estimate(for: key, logs: logs, now: now)
    }

    public func forecast(for key: String, now: Date = Date()) -> Forecast? {
        Estimator.forecast(for: key, logs: logs, now: now)
    }

    /// The key a device's estimate is kept under: its Bluetooth address, which every
    /// Mac sees the same, so usage on your other Macs adds up.
    public static func key(for device: DeviceBattery) -> String {
        device.keys.filter { $0.hasPrefix("bt:") }.sorted().first ?? device.id
    }

    public func markCharged(_ key: String, ranOut: Bool, at date: Date = Date()) {
        ownLog.charges.append(ChargeMark(device: key, date: date, ranOut: ranOut, mac: ownLog.macID,
                                         minutesBefore: ownLog.minutes[key]?[String(UsageLog.hour(date))] ?? 0))
        dirty = true
        save()
        updateTracking()
        emit()
        SharedContainer.log("estimate: \(key) marked charged\(ranOut ? " after running out" : "")")
    }

    /// Takes back the most recent mark made on this Mac, for a mistaken tap.
    public func undoLastMark(_ key: String) {
        guard let index = ownLog.charges.lastIndex(where: { $0.device == key }) else { return }
        ownLog.charges.remove(at: index)
        dirty = true
        save()
        updateTracking()
        emit()
    }

    /// Forgets every mark and all usage of a device on this Mac.
    public func stopEstimating(_ key: String) {
        ownLog.charges.removeAll { $0.device == key }
        ownLog.minutes[key] = nil
        dirty = true
        save()
        updateTracking()
        emit()
    }

    private func updateTracking() {
        usage.tracked = trackedKeys.filter(isReporting)
        let syncing = isSyncing ? "iCloud Drive, \(others.count) other Macs" : "this Mac only"
        let heard = usage.heard.isEmpty ? "no input yet" : "input from \(usage.heard.sorted().joined(separator: ", "))"
        status = "\(usage.tracked.count) devices; \(usage.status), \(heard); \(syncing)"
    }

    private func emit() {
        let now = Date()
        let readings = trackedKeys.filter(isReporting).sorted().compactMap { key -> BatteryReading? in
            guard let estimate = estimate(for: key, now: now) else { return nil }
            let described = describe(key)
            // Not "connected": whether it is comes from the sources that can see it.
            return BatteryReading(keys: [key], name: described?.name ?? "Device", kind: described?.kind ?? .other,
                                  percent: estimate.percent, isConnected: false, source: .estimate, date: now)
        }
        onReadings?(readings)
    }

    // MARK: - Files

    public func save() {
        guard let folder else { return }
        ownLog.prune(before: Date().addingTimeInterval(-Self.usageRetention))
        ownLog.updated = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ownLog) else { return }
        let url = folder.appendingPathComponent("\(ownLog.macID).json")
        var coordinationError: NSError?
        var writeError: Error?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try data.write(to: target, options: .atomic) } catch { writeError = error }
            }
        } catch {
            writeError = error
        }
        if let error = coordinationError ?? writeError {
            SharedContainer.log("estimate: couldn't save usage: \(error.localizedDescription)")
            return
        }
        dirty = false
        lastSave = Date()
    }

    private func readOthers() {
        lastRead = Date()
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            // A file iCloud has evicted: ask for it back and use it next time.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                continue
            }
            guard name.hasSuffix(".json"), name != "\(ownLog.macID).json",
                  let log = Self.read(folder.appendingPathComponent(name)) else { continue }
            others[log.macID] = log
        }
    }

    private static func read(_ url: URL) -> UsageLog? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageLog.self, from: data)
    }
}
