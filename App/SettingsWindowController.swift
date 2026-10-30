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
    private var fitting = false
    /// The Devices tab's size when you've made the window bigger, kept across tabs and launches.
    private var devicesSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "settingsDevicesSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "settingsDevicesSize") }
    }

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

    /// Resizes the window for the tab, keeping its top edge in place: the other tabs to
    /// their natural height, the Devices tab to the size you last gave it (it fills the
    /// window, so the list and the chart get the room). Never bigger than the screen.
    private func fit(_ tab: SettingsTab, animate: Bool) {
        guard let window else { return }
        fitting = true
        defer { fitting = false }
        let natural = ceil(NSHostingView(rootView: SettingsView(model: model, tabState: tabState).measuring(tab)).fittingSize.height)
        let screen = window.screen ?? NSScreen.main
        let room = screen?.visibleFrame.size ?? NSSize(width: 1400, height: 880)
        let maxHeight = room.height - 80
        var size = NSSize(width: SettingsView.width, height: min(natural, maxHeight))
        if tab == .devices, let saved = devicesSize {
            size = NSSize(width: max(size.width, saved.width), height: max(size.height, saved.height))
        }
        size = NSSize(width: min(size.width, room.width - 40), height: min(size.height, maxHeight))
        window.contentMinSize = NSSize(width: SettingsView.width, height: min(240, size.height))
        // Only the Devices tab has anything to gain from being taller than its contents.
        window.contentMaxSize = NSSize(width: room.width, height: tab == .devices ? maxHeight : min(natural, maxHeight))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !fitting, tabState.tab == .devices, let window else { return }
        devicesSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowWillClose(_ notification: Notification) {
        model.watchPermissions(false)
        // Commits a name being edited.
        window?.makeFirstResponder(nil)
    }
}
