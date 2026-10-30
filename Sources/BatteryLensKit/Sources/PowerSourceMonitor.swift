import BatteryLensShared
import Foundation
import IOKit.ps

/// The power-source list: the Mac's own battery, and the accessories `pmset -g accps`
/// shows (Bluetooth LE mice and keyboards, AirPods and their case). Needs no permission.
///
/// The public IOPSCopyPowerSourcesInfo only has the internal battery and UPSes; the
/// accessories come from the private IOPSCopyPowerSourcesByType(0), found with dlsym so
/// the app still runs, without them, if it ever disappears.
public final class PowerSourceMonitor: BatterySource {
    public let kind = SourceKind.powerList
    public private(set) var status = "not started"
    public var onReadings: (([BatteryReading]) -> Void)?

    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private let copyByType: CopyByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyByType.self)
    }()
    private var notificationSource: CFRunLoopSource?
    private var timer: Timer?

    public init() {}

    public func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Fires for the internal battery; accessories are caught by the timer.
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            notificationSource = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        var descriptions: [[String: Any]] = []
        var seen = Set<String>()
        var blobs: [CFTypeRef] = []
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() { blobs.append(info) }
        if let copyByType, let info = copyByType(0)?.takeRetainedValue() { blobs.append(info) }
        for blob in blobs {
            for source in IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? [] {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                let id = info[kIOPSPowerSourceIDKey].map { "\($0)" } ?? info[kIOPSNameKey] as? String ?? UUID().uuidString
                if seen.insert(id).inserted { descriptions.append(info) }
            }
        }
        let readings = descriptions.flatMap { Self.readings(from: $0) }
        status = copyByType == nil ? "accessory list unavailable; \(readings.count) sources" : "\(readings.count) sources"
        onReadings?(readings)
    }

    /// Maps one power-source description to readings. AirPods list both buds as one
    /// "Combined" source with each bud under "Combined Parts"; those become one reading
    /// per bud, named like the combined source.
    static func readings(from info: [String: Any], macName: String = Host.current().localizedName ?? "Mac",
                         now: Date = Date()) -> [BatteryReading] {
        if let parts = info["Combined Parts"] as? [[String: Any]], !parts.isEmpty {
            return parts.compactMap { part in
                var part = part
                if part[kIOPSNameKey] == nil { part[kIOPSNameKey] = info[kIOPSNameKey] }
                if part[kIOPSTypeKey] == nil { part[kIOPSTypeKey] = info[kIOPSTypeKey] }
                return reading(from: part, macName: macName, now: now)
            }
        }
        return reading(from: info, macName: macName, now: now).map { [$0] } ?? []
    }

    static func reading(from info: [String: Any], macName: String = Host.current().localizedName ?? "Mac",
                        now: Date = Date()) -> BatteryReading? {
        guard let current = info[kIOPSCurrentCapacityKey] as? Int else { return nil }
        let max = info[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = max > 0 ? min(100, current * 100 / max) : current
        let charging = info[kIOPSIsChargingKey] as? Bool ?? false
        let type = info[kIOPSTypeKey] as? String ?? ""

        if type == kIOPSInternalBatteryType {
            return BatteryReading(keys: ["mac:internal"], name: macName, kind: .mac, percent: percent,
                                  isCharging: charging, source: .powerList, date: now)
        }

        let name = info[kIOPSNameKey] as? String ?? "Accessory"
        let category = info["Accessory Category"] as? String ?? ""
        var keys = Set<String>()
        if let id = info["Accessory Identifier"] as? String { keys.insert("uuid:\(id)") }
        // AirPods list each bud and the case separately; the group ties them together.
        if let group = info["Group Identifier"] as? String { keys.insert("group:\(group)") }

        var part: BatteryPart?
        switch (info["Part Identifier"] as? String)?.lowercased() {
        case "left": part = .left
        case "right": part = .right
        case "case": part = .chargingCase
        default: if category == "Audio Battery Case" { part = .chargingCase }
        }

        let kind: DeviceKind
        switch category {
        case "Mouse": kind = .mouse
        case "Keyboard": kind = .keyboard
        case "Trackpad": kind = .trackpad
        case "Headset", "Headphones", "Audio Battery Case": kind = part == nil && info["Group Identifier"] == nil ? .headphones : .earbuds
        case "Game Controller": kind = .controller
        case "Stylus", "Pencil": kind = .stylus
        default: kind = .other
        }
        return BatteryReading(keys: keys, name: name, kind: kind, part: part, percent: percent, isCharging: charging,
                              source: .powerList, date: now)
    }
}
