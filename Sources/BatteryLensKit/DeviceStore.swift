import BatteryLensShared
import Foundation

/// Your own choices for one device. Phase 3 adds the settings that edit them.
public struct DeviceSettings: Codable, Hashable, Sendable {
    public var customName: String?
    /// Hidden from the widget and the menu bar summary, but still listed in Settings.
    public var isHidden = false
    public var lowThreshold: Int?
    /// Off for a device shared with other computers: no widget entry, no alerts, no estimate.
    public var isReporting = true

    public init(customName: String? = nil, isHidden: Bool = false, lowThreshold: Int? = nil, isReporting: Bool = true) {
        self.customName = customName
        self.isHidden = isHidden
        self.lowThreshold = lowThreshold
        self.isReporting = isReporting
    }

    var isDefault: Bool { self == DeviceSettings() }
}

/// What the app remembers about a device between readings and between launches.
public struct RememberedDevice: Codable, Hashable, Sendable {
    public var id: String
    /// The name the sources gave it; a custom name lives in its settings.
    public var name: String
    public var kind: DeviceKind
    public var keys: Set<String>
    /// The last level seen for each battery.
    public var levels: [DeviceBattery.Level]
    public var firstSeen: Date
    /// When it was last connected.
    public var lastSeen: Date
}

/// Remembers every device the sources have reported, so one that disconnects or goes to
/// sleep stays listed, dimmed, with its last-known levels and their age. Keeps device IDs
/// stable across launches and applies each device's settings.
///
/// Saved as JSON in Application Support (the app isn't sandboxed); the widget only ever
/// sees the snapshot built from it.
public final class DeviceStore {
    private struct Saved: Codable {
        var devices: [RememberedDevice]
        var settings: [String: DeviceSettings]
    }

    /// Devices not seen for this long are forgotten, unless you changed their settings.
    public static let retention: TimeInterval = 60 * 24 * 3600

    public private(set) var remembered: [String: RememberedDevice] = [:]
    public private(set) var settings: [String: DeviceSettings] = [:]
    /// Which device each identifier belongs to; the merger reuses these IDs.
    public var knownIDs: [String: String] = [:]
    /// The low-battery level for devices without their own (Settings › Alerts).
    public var defaultLowThreshold = DeviceBattery.defaultLowThreshold

    private let fileURL: URL?
    private var lastSaved: Data?
    private var lastSaveDate = Date.distantPast
    private var structureChanged = false

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL? = DeviceStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    public static var defaultURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("BatteryLens/devices.json")
    }

    // MARK: - Updating

    /// Folds the merged live devices into what's remembered, and returns every device:
    /// live ones, then remembered ones no source reports right now, as disconnected.
    /// Settings are applied (names, thresholds); hidden devices are still included.
    public func update(with live: [DeviceBattery], now: Date = Date()) -> [DeviceBattery] {
        var result: [DeviceBattery] = []
        var liveIDs = Set<String>()
        for var device in live {
            absorbDuplicates(of: device)
            liveIDs.insert(device.id)
            let previous = remembered[device.id]
            if previous == nil { structureChanged = true }
            var entry = previous ?? RememberedDevice(id: device.id, name: device.name, kind: device.kind, keys: [],
                                                     levels: [], firstSeen: now, lastSeen: now)
            if entry.name != device.name || entry.kind != device.kind || !device.keys.isSubset(of: entry.keys) {
                structureChanged = true
            }
            entry.name = device.name
            if device.kind != .other { entry.kind = device.kind }
            entry.keys.formUnion(device.keys)

            if device.isConnected {
                entry.lastSeen = now
                entry.levels = merged(device.levels, over: entry.levels)
            } else {
                // A disconnected device reported only by System Information: the levels seen
                // while it was connected are more accurate and carry their true age.
                // An estimate is recomputed live, so a fresh one beats the remembered one.
                device.levels = merged(entry.levels.filter { $0.source != .estimate }, over: device.levels)
                if previous != nil { device.updated = entry.lastSeen }
                if entry.levels.isEmpty || device.levels.contains(where: { $0.source == .estimate }) {
                    entry.levels = device.levels
                }
            }
            remembered[device.id] = entry
            for key in entry.keys { knownIDs[key] = device.id }
            result.append(applySettings(to: device))
        }

        for entry in remembered.values where !liveIDs.contains(entry.id) {
            if now.timeIntervalSince(entry.lastSeen) > Self.retention, settings[entry.id] == nil {
                forget(entry.id)
                continue
            }
            let device = DeviceBattery(id: entry.id, name: entry.name, kind: entry.kind, keys: entry.keys,
                                       levels: entry.levels, isConnected: false, updated: entry.lastSeen)
            result.append(applySettings(to: device))
        }
        saveIfNeeded(now: now)
        return DeviceMerger.sorted(result)
    }

    /// The devices for the widget and the menu bar summary.
    public func visible(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        devices.filter { device in
            let settings = settings[device.id] ?? DeviceSettings()
            return !settings.isHidden && settings.isReporting
        }
    }

    // MARK: - Settings

    public func settings(for id: String) -> DeviceSettings { settings[id] ?? DeviceSettings() }

    public func setSettings(_ new: DeviceSettings, for id: String) {
        settings[id] = new.isDefault ? nil : new
        structureChanged = true
        saveIfNeeded()
    }

    /// Removes a device; it comes back as new if a source reports it again.
    public func forget(_ id: String) {
        guard let entry = remembered.removeValue(forKey: id) else { return }
        settings[id] = nil
        for key in entry.keys where knownIDs[key] == id { knownIDs[key] = nil }
        structureChanged = true
    }

    // MARK: - Helpers

    /// When a device now shares identifiers with another remembered entry (two sources
    /// first seen apart, then joined), the other entry is folded into this one.
    private func absorbDuplicates(of device: DeviceBattery) {
        for other in remembered.values where other.id != device.id && !other.keys.isDisjoint(with: device.keys) {
            remembered[other.id] = nil
            if var entry = remembered[device.id] {
                entry.keys.formUnion(other.keys)
                entry.firstSeen = min(entry.firstSeen, other.firstSeen)
                remembered[device.id] = entry
            }
            if settings[device.id] == nil, let moved = settings[other.id] { settings[device.id] = moved }
            settings[other.id] = nil
            structureChanged = true
        }
    }

    /// One level per battery: `newer`'s where it has one, `older`'s for the rest.
    private func merged(_ newer: [DeviceBattery.Level], over older: [DeviceBattery.Level]) -> [DeviceBattery.Level] {
        let parts = Set(newer.map(\.part))
        let order: [BatteryPart?] = [nil, .left, .right, .chargingCase]
        return (newer + older.filter { !parts.contains($0.part) })
            .sorted { order.firstIndex(of: $0.part)! < order.firstIndex(of: $1.part)! }
    }

    private func applySettings(to device: DeviceBattery) -> DeviceBattery {
        var device = device
        let settings = settings[device.id] ?? DeviceSettings()
        if let name = settings.customName, !name.isEmpty { device.name = name }
        device.lowThreshold = settings.lowThreshold ?? defaultLowThreshold
        return device
    }

    // MARK: - Saving

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data) else {
            SharedContainer.log("store: couldn't read \(fileURL.lastPathComponent); starting fresh")
            return
        }
        remembered = Dictionary(saved.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        settings = saved.settings
        for entry in saved.devices {
            for key in entry.keys { knownIDs[key] = entry.id }
        }
        lastSaved = data
    }

    /// Levels change every few seconds, so routine updates are saved at most every five
    /// minutes; a new device, a name or a settings change is saved straight away.
    public func saveIfNeeded(now: Date = Date(), force: Bool = false) {
        guard let fileURL else { return }
        guard force || structureChanged || now.timeIntervalSince(lastSaveDate) > 300 else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let saved = Saved(devices: remembered.values.sorted { $0.id < $1.id }, settings: settings)
        guard let data = try? encoder.encode(saved) else { return }
        structureChanged = false
        lastSaveDate = now
        guard data != lastSaved else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastSaved = data
        } catch {
            SharedContainer.log("store: couldn't save: \(error.localizedDescription)")
        }
    }
}
