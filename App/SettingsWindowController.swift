import AppKit
import Combine
import SwiftUI

/// "BatteryLens Settings", hosted in AppKit so the menu bar app can open it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let tabState = SettingsTabState()
    private var window: NSWindow?
    private var tabObserver: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil { window = makeWindow() }
        if let tab { tabState.tab = tab }
        model.watchPermissions(true)
        fit(tabState.tab, animate: false)
        if window?.isVisible == false { window?.center() }
        // On macOS 27 an accessory app is only activated once it has a window on screen.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        // Sized here, to each tab's natural height capped to the screen. Letting SwiftUI
        // size the window crashes once content outgrows the screen (see M3 Tracker).
        let hosting = NSHostingController(rootView: SettingsView(model: model, tabState: tabState))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "BatteryLens Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // @Published reports the new tab before it's stored; fit on the next turn.
        tabObserver = tabState.$tab.dropFirst().receive(on: RunLoop.main).sink { [weak self] tab in
            self?.fit(tab, animate: true)
        }
        return window
    }

    /// Resizes the window to the tab's natural height, no taller than the screen,
    /// keeping its top edge in place.
    private func fit(_ tab: SettingsTab, animate: Bool) {
        guard let window else { return }
        let width = SettingsView.width
        let natural = ceil(NSHostingView(rootView: SettingsView(model: model, tabState: tabState).measuring(tab)).fittingSize.height)
        let screen = window.screen ?? NSScreen.main
        let height = min(natural, (screen?.visibleFrame.height ?? 800) - 80)
        window.contentMinSize = NSSize(width: width, height: min(240, height))
        window.contentMaxSize = NSSize(width: width, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        model.watchPermissions(false)
        // Commits a name being edited.
        window?.makeFirstResponder(nil)
    }
}
