import AppKit
import Observation

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        MenuHub.shared.reload()
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
