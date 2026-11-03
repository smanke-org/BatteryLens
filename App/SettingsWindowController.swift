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
    /// The open Settings controller, for the What's New… button.
    static weak var current: SettingsWindowController?

    /// The content size you last dragged the window to (per Mac, not synced), kept for every
    /// tab and next time; nil until you do, and each tab opens at its own height.
    static var chosenSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }
    static let minimumHeight: CGFloat = 280
    /// The smallest and largest content size the shown tab allows. Set as the window's
    /// contentMinSize/contentMaxSize too, but a window whose content is a hosting controller
    /// drops those once it's shown, so dragging is held to them in windowWillResize.
    private var minimumContent = NSSize(width: SettingsView.width, height: 280)
    private var maximumContent = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.current = self
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
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }

    var isVisible: Bool { window?.isVisible == true }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

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

    /// Resizes the window for the tab, keeping its top edge in place: to its natural height
    /// until you drag the window to a size, then every tab to that size (tabs fill the window
    /// and scroll when they hold more). Never bigger than the screen.
    private func fit(_ tab: SettingsTab, animate: Bool) {
        guard let window else { return }
        fitting = true
        defer { fitting = false }
        let natural = ceil(NSHostingView(rootView: SettingsView(model: model, tabState: tabState).measuring(tab)).fittingSize.height)
        let screen = window.screen ?? NSScreen.main
        let room = screen?.visibleFrame.size ?? NSSize(width: 1400, height: 880)
        let maxHeight = room.height - 80
        var size = NSSize(width: SettingsView.width, height: min(natural, maxHeight))
        if let chosen = Self.chosenSize {
            size = NSSize(width: max(chosen.width, SettingsView.width), height: max(chosen.height, Self.minimumHeight))
        }
        size = NSSize(width: min(size.width, room.width - 40), height: min(size.height, maxHeight))
        minimumContent = NSSize(width: SettingsView.width, height: min(Self.minimumHeight, size.height))
        maximumContent = NSSize(width: room.width, height: maxHeight)
        window.contentMinSize = minimumContent
        window.contentMaxSize = maximumContent
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: min(max(content.width, minimumContent.width), maximumContent.width),
                             height: min(max(content.height, minimumContent.height), maximumContent.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !fitting, let window else { return }
        Self.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowWillClose(_ notification: Notification) {
        model.watchPermissions(false)
        // Commits a name being edited.
        window?.makeFirstResponder(nil)
    }
}
