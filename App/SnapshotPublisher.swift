import BatteryLensShared
import Foundation
import WidgetKit

/// Writes every change to the App Group for the widget, and asks WidgetKit to reload
/// only when the change is visible enough to matter (see SnapshotDiff): reloads are
/// budgeted, and the widget picks up the latest snapshot whenever it does run.
final class SnapshotPublisher {
    private var lastReloaded: [DeviceBattery]?

    func publish(_ devices: [DeviceBattery]) {
        do {
            try SharedContainer.write(Snapshot(devices: devices, appVersion: AppInfo.versionString))
            // Unified log only (not activity.log): what was written, for checking from outside.
            let summary = devices.map { device in
                "\(device.name) [\(device.levels.map { "\($0.part?.shortName ?? "")\($0.percent)%/\($0.source.rawValue)" }.joined(separator: " "))]"
                    + (device.isConnected ? "" : " (disconnected)")
                    + (device.forecast.map { " {\($0.shortText()) by \($0.basis.rawValue)}" } ?? "")
            }
            SharedContainer.logger.info("app: wrote snapshot: \(summary.joined(separator: "; "), privacy: .public)")
        } catch {
            SharedContainer.log("app: couldn't write the snapshot: \(error.localizedDescription)")
            return
        }
        guard let reason = SnapshotDiff.reloadReason(from: lastReloaded, to: devices) else { return }
        lastReloaded = devices
        WidgetCenter.shared.reloadAllTimelines()
        SharedContainer.log("app: asked widget to reload — \(reason)")
    }
}
