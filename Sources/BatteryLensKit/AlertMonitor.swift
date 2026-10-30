import BatteryLensShared
import Foundation

/// Decides when to notify: a low battery once per discharge, and optionally a full one
/// once per charge. Pure logic; the app shows the notifications.
///
/// A low alert re-arms when the battery charges or climbs back above its level by a
/// margin, so a reading wobbling around the threshold doesn't alert twice. Earbud cases
/// and the Mac (macOS warns about its own battery) are left out.
public final class AlertMonitor {
    public enum Kind: String, Codable, Sendable { case low, full }

    public struct Alert: Hashable, Sendable {
        public var kind: Kind
        public var deviceID: String
        public var title: String
        public var body: String
    }

    public static let rearmMargin = 5
    public static let fullLevel = 100
    /// A full alert re-arms once the battery drops below this.
    public static let fullRearmLevel = 95

    /// Alerts already given, as "kind/device/part"; saved so a relaunch doesn't repeat them.
    public private(set) var fired: Set<String>
    public var onFiredChange: ((Set<String>) -> Void)?

    public init(fired: Set<String> = []) {
        self.fired = fired
    }

    /// The alerts `devices` call for now. `devices` are the visible ones (hidden and
    /// not-reporting devices never alert).
    public func check(_ devices: [DeviceBattery], lowEnabled: Bool, fullEnabled: Bool) -> [Alert] {
        var alerts: [Alert] = []
        let before = fired
        for device in devices where device.isConnected && device.kind != .mac {
            for level in device.levels where level.part != .chargingCase {
                let id = "\(device.id)/\(level.part?.rawValue ?? "main")"
                let label = device.name + (level.part.map { $0 == .left ? " (left)" : $0 == .right ? " (right)" : "" } ?? "")
                let lowKey = "low/" + id, fullKey = "full/" + id

                if level.isCharging || level.percent > device.threshold + Self.rearmMargin {
                    fired.remove(lowKey)
                } else if level.percent <= device.threshold, !fired.contains(lowKey) {
                    fired.insert(lowKey)
                    if lowEnabled {
                        alerts.append(Alert(kind: .low, deviceID: device.id, title: "\(label) battery low",
                                            body: level.source == .estimate
                                                ? "About \(level.percent)% left, by BatteryLens's estimate. Charge it soon."
                                                : "\(level.percent)% left. Charge it soon."))
                    }
                }

                if level.percent < Self.fullRearmLevel {
                    fired.remove(fullKey)
                } else if level.isCharging, level.percent >= Self.fullLevel, !fired.contains(fullKey) {
                    fired.insert(fullKey)
                    if fullEnabled {
                        alerts.append(Alert(kind: .full, deviceID: device.id, title: "\(label) fully charged",
                                            body: "You can unplug it."))
                    }
                }
            }
        }
        if fired != before { onFiredChange?(fired) }
        return alerts
    }
}
