import Foundation

/// The app's own settings as settings sync sees them. The values live in UserDefaults
/// (see AppSettings) and on AppModel, which reloads them when another Mac's arrive.
@MainActor
final class Preferences {
    static let shared = Preferences()

    /// The settings that follow you between Macs. The menu bar's chosen device and
    /// everything per device (names, thresholds, reporting) stay on each Mac.
    static let keys = [AppSettings.Key.lowAlerts, AppSettings.Key.fullAlerts,
                       AppSettings.Key.defaultLowThreshold, AppSettings.Key.menuBarShowsPercent, AppSettings.Key.confirmQuit]

    /// Called after another Mac's settings were written into UserDefaults.
    var onReload: (() -> Void)?

    /// Every synced setting's current value, defaults included, so a Mac adopting the
    /// file never mistakes a setting at its default for a missing one.
    var snapshot: [String: Any] {
        var values: [String: Any] = [:]
        for key in Self.keys { values[key] = AppSettings.defaults.object(forKey: key) }
        return values
    }

    func reload() { onReload?() }
}
