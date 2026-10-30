import Foundation

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case mac, mouse, keyboard, trackpad, headphones, earbuds, controller, stylus, other

    public var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .mouse: "computermouse.fill"
        case .keyboard: "keyboard.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .headphones: "headphones"
        case .earbuds: "airpodspro"
        case .controller: "gamecontroller.fill"
        case .stylus: "pencil"
        case .other: "battery.100percent"
        }
    }
}

/// Which battery of a device with several: earbuds and their case.
public enum BatteryPart: String, Codable, Sendable, CaseIterable {
    case left, right, chargingCase

    public var shortName: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .chargingCase: "Case"
        }
    }
}

/// Where a reading came from. Declared in order of trust: when two sources report the
/// same battery, the earlier one wins.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Comparable {
    /// Logitech HID++: exact percentage and charging state.
    case logitech
    /// The power-source list `pmset -g accps` shows.
    case powerList
    /// Bluetooth LE Battery Service (0x180F).
    case ble
    /// Battery Strength sent in a HID report.
    case hid
    case controller
    /// System Information; slow to refresh, but keeps AirPods levels after they disconnect.
    case profiler
    case estimate

    public static func < (lhs: SourceKind, rhs: SourceKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var displayName: String {
        switch self {
        case .logitech: "Logitech"
        case .powerList: "Power sources"
        case .ble: "Bluetooth LE"
        case .hid: "HID reports"
        case .controller: "Game controllers"
        case .profiler: "System Information"
        case .estimate: "Estimate"
        }
    }
}

/// One source's view of one battery, or of a connected device with no level to report.
public struct BatteryReading: Codable, Hashable, Sendable {
    /// Identifiers that tie readings of one physical device together across sources:
    /// "uuid:…" (Bluetooth LE devices; the same in IOKit and CoreBluetooth),
    /// "bt:aa:bb:…" (Bluetooth address), "group:…" (AirPods parts), "logi:unit-…".
    public var keys: Set<String>
    public var name: String
    public var kind: DeviceKind
    public var part: BatteryPart?
    /// Nil for a connected device that reports no level (the Matias keyboard).
    public var percent: Int?
    public var isCharging: Bool
    public var isConnected: Bool
    public var source: SourceKind
    public var date: Date

    public init(keys: Set<String>, name: String, kind: DeviceKind, part: BatteryPart? = nil, percent: Int?,
                isCharging: Bool = false, isConnected: Bool = true, source: SourceKind, date: Date = Date()) {
        self.keys = keys
        self.name = name
        self.kind = kind
        self.part = part
        self.percent = percent
        self.isCharging = isCharging
        self.isConnected = isConnected
        self.source = source
        self.date = date
    }
}

/// One physical device with its best reading for each battery.
public struct DeviceBattery: Codable, Hashable, Identifiable, Sendable {
    public struct Level: Codable, Hashable, Sendable {
        public var part: BatteryPart?
        public var percent: Int
        public var isCharging: Bool
        public var source: SourceKind
        public var date: Date

        public init(part: BatteryPart?, percent: Int, isCharging: Bool, source: SourceKind, date: Date) {
            self.part = part
            self.percent = percent
            self.isCharging = isCharging
            self.source = source
            self.date = date
        }
    }

    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var keys: Set<String>
    /// Main battery first, then left, right, case.
    public var levels: [Level]
    public var isConnected: Bool
    /// When a source last reported the device; for a disconnected one, its last-known levels' age.
    public var updated: Date
    /// The device's own low-battery level when set in its settings.
    public var lowThreshold: Int?
    /// When it should run out, or finish charging; nil until there's enough history.
    public var forecast: Forecast?

    public static let defaultLowThreshold = 20

    public init(id: String, name: String, kind: DeviceKind, keys: Set<String>, levels: [Level], isConnected: Bool,
                updated: Date, lowThreshold: Int? = nil, forecast: Forecast? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.keys = keys
        self.levels = levels
        self.isConnected = isConnected
        self.updated = updated
        self.lowThreshold = lowThreshold
        self.forecast = forecast
    }

    public var threshold: Int { lowThreshold ?? Self.defaultLowThreshold }

    /// The level that matters for warnings: the lowest of the batteries in use (a case
    /// only counts when it's the only one reporting).
    public var lowest: Int? {
        let inUse = levels.filter { $0.part != .chargingCase }
        return (inUse.isEmpty ? levels : inUse).map(\.percent).min()
    }

    public var isCharging: Bool { levels.contains { $0.isCharging && $0.part != .chargingCase } }
}

/// When a battery should run out or be full.
public struct Forecast: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case empty, full }
    /// Where the figure comes from: macOS (the Mac's own battery), the recent drain or
    /// charge rate, or for an estimated device, your usual daily use of it.
    public enum Basis: String, Codable, Sendable { case system, rate, usage }

    public var kind: Kind
    public var date: Date
    public var basis: Basis

    public init(kind: Kind, date: Date, basis: Basis) {
        self.kind = kind
        self.date = date
        self.basis = basis
    }

    /// "3d left", "5h left", "full in 40m": for the widget.
    public func shortText(now: Date = Date()) -> String {
        let span = Self.span(max(0, date.timeIntervalSince(now)))
        return kind == .empty ? "\(span) left" : "full in \(span)"
    }

    /// "About 3 days left", "Full in about 40 minutes".
    public func text(now: Date = Date()) -> String {
        let span = Self.longSpan(max(0, date.timeIntervalSince(now)))
        return kind == .empty ? "About \(span) left" : "Full in about \(span)"
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((seconds / 86400).rounded()))d"
    }

    static func longSpan(_ seconds: TimeInterval) -> String {
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return unit(max(1, minutes), "minute") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return unit(hours, "hour") }
        return unit(Int((seconds / 86400).rounded()), "day")
    }
}

/// What the app writes for the widget.
public struct Snapshot: Codable, Sendable {
    public var devices: [DeviceBattery]
    public var written: Date
    public var appVersion: String

    public init(devices: [DeviceBattery], written: Date = Date(), appVersion: String) {
        self.devices = devices
        self.written = written
        self.appVersion = appVersion
    }

    /// For the widget gallery and placeholders. Placeholder names only.
    public static let sample = Snapshot(devices: [
        DeviceBattery(id: "sample-mac", name: "MacBook Pro", kind: .mac, keys: [],
                      levels: [.init(part: nil, percent: 82, isCharging: true, source: .powerList, date: Date())],
                      isConnected: true, updated: Date()),
        DeviceBattery(id: "sample-mouse", name: "Mouse", kind: .mouse, keys: [],
                      levels: [.init(part: nil, percent: 64, isCharging: false, source: .powerList, date: Date())],
                      isConnected: true, updated: Date()),
        DeviceBattery(id: "sample-keyboard", name: "Keyboard", kind: .keyboard, keys: [],
                      levels: [.init(part: nil, percent: 15, isCharging: false, source: .ble, date: Date())],
                      isConnected: true, updated: Date()),
        DeviceBattery(id: "sample-earbuds", name: "Earbuds", kind: .earbuds, keys: [],
                      levels: [.init(part: .left, percent: 90, isCharging: false, source: .powerList, date: Date()),
                               .init(part: .right, percent: 88, isCharging: false, source: .powerList, date: Date())],
                      isConnected: true, updated: Date()),
    ], appVersion: "sample")
}
