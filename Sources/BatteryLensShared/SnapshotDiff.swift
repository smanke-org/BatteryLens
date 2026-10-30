import Foundation

/// WidgetKit limits how often an app may reload its widgets, so the app only asks
/// when something visible changed enough to matter. Compared against the devices at
/// the last reload, so a battery draining 1% at a time still triggers one every 5%.
public enum SnapshotDiff {
    public static let percentStep = 5

    /// Why the widget should reload, or nil if it needn't.
    public static func reloadReason(from old: [DeviceBattery]?, to new: [DeviceBattery]) -> String? {
        guard let old else { return "first snapshot" }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let added = after.keys.first(where: { before[$0] == nil }) { return "\(after[added]!.name) appeared" }
        if let removed = before.keys.first(where: { after[$0] == nil }) { return "\(before[removed]!.name) went away" }

        for (id, device) in after {
            let previous = before[id]!
            if device.isConnected != previous.isConnected {
                return "\(device.name) \(device.isConnected ? "connected" : "disconnected")"
            }
            let oldLevels = Dictionary(previous.levels.map { ($0.part, $0) }, uniquingKeysWith: { first, _ in first })
            for level in device.levels {
                let label = device.name + (level.part.map { " \($0.shortName)" } ?? "")
                guard let was = oldLevels[level.part] else { return "\(label) now reports a level" }
                if level.isCharging != was.isCharging { return "\(label) \(level.isCharging ? "started" : "stopped") charging" }
                if abs(level.percent - was.percent) >= percentStep { return "\(label) \(was.percent)% → \(level.percent)%" }
                let low = device.threshold
                if (level.percent <= low) != (was.percent <= low) { return "\(label) crossed \(low)%" }
            }
            if previous.levels.count != device.levels.count { return "\(device.name) battery list changed" }
            if device.name != previous.name { return "\(previous.name) renamed" }
            if device.threshold != previous.threshold { return "\(device.name) low level changed" }
        }
        return nil
    }
}
