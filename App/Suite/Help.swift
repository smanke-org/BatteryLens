import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// Kept for the shared Help views: BatteryLens has no shortcuts of its own to fill in.
    static func resolve(_ text: String) -> String { text }

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: SettingsTab) -> String {
        switch tab {
        case .general: "sync"
        case .devices: "devices"
        case .alerts: "alerts"
        case .menuBar: "menu-bar"
        case .permissions: "permissions"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("BatteryLens shows the battery of every device connected to your Mac in one place: the Mac itself, AirPods and other earbuds, Bluetooth mice, keyboards and trackpads, Logitech devices, game controllers, and even keyboards that never report a level, which it estimates."),
            .text("It lives in the menu bar and in a desktop widget. Click the menu bar icon for every device, with its level, whether it's charging, and how long it should last."),
            .heading("Where the levels come from"),
            .keys([
                ("Power sources", "The list macOS keeps for the Mac and many Apple and Bluetooth accessories"),
                ("Bluetooth LE", "The standard battery level many mice, keyboards and headphones report (needs Bluetooth permission)"),
                ("Logitech", "Exact levels from Logitech devices (needs Input Monitoring)"),
                ("HID reports", "Keyboards and mice that send their battery along with their input (needs Input Monitoring)"),
                ("System Information", "Keeps AirPods levels after they disconnect"),
                ("Estimate", "For a device that reports nothing: worked out from how much you use it"),
            ]),
            .tip("A device that disconnects stays in the list, dimmed, with its last-known level and how long ago that was."),
            .tip("While ToolHUD is running, BatteryLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings › General."),
            .tip("Quitting asks first, since the widget, menu bar levels and alerts stop updating while BatteryLens is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "widget", title: "The Widget", symbol: "square.grid.2x2", blocks: [
            .text("Add BatteryLens to your desktop or Notification Center: right-click the desktop, choose Edit Widgets, and search for BatteryLens. It comes in small, medium, large and extra large."),
            .text("Right-click a placed widget and choose Edit \"BatteryLens\" to set it up:"),
            .keys([
                ("Style", "Rings, like Apple's Batteries widget, or bars with numbers"),
                ("Devices", "All connected devices, or the ones you pick"),
                ("Include disconnected", "Also show devices that are switched off, with their last-known level"),
            ]),
            .text("Estimated levels show with a \"~\" and a dashed ring. In the bars style, the bolt-and-check button next to an estimated device marks it as charged."),
            .tip("The widget updates when a level moves by 5%, a device connects or disconnects, starts or stops charging, or crosses its low-battery level. macOS limits how often widgets refresh, so the bottom line shows how old the levels are."),
        ]),

        HelpTopic(id: "devices", title: "Devices", symbol: "battery.75percent", blocks: [
            .text("Settings › Devices lists every device BatteryLens has seen. Select one to change it:"),
            .keys([
                ("Name", "Your own name for it, shown everywhere. Leave it empty to use the device's own name"),
                ("Report this device", "Turn this off for a keyboard or mouse you share with another computer. It then leaves the widget, the menu bar, alerts and estimates, and its use stops being counted"),
                ("Show in the widget and menu bar", "Hide a device without forgetting it"),
                ("Low battery alert at", "This device's own low level, instead of the default in Alerts"),
                ("Forget Device…", "Removes a disconnected device and its settings. If it connects again, it comes back as new"),
            ]),
            .tip("Click a device in the menu bar menu to jump straight to it here."),
            .text("BatteryLens forgets a device on its own after 60 days without seeing it."),
        ]),

        HelpTopic(id: "estimates", title: "Estimated Batteries", symbol: "keyboard", blocks: [
            .text("Some keyboards and mice never tell the Mac their battery level. BatteryLens can estimate one from how much you use it."),
            .heading("Starting an estimate"),
            .text("Charge the device fully, then select it in Settings › Devices and click Mark as Charged (or use the button on the bars widget). From then on BatteryLens counts the minutes you type or click on it. It records only that you used it in a given minute, never what you typed."),
            .heading("Teaching it how long a charge lasts"),
            .text("At first it assumes a charge lasts about 100 hours of use. When the device runs flat, charge it and click It Ran Out, Now Charged: BatteryLens then knows how many hours that charge really lasted, and uses the average of the last three."),
            .keys([
                ("Mark as Charged", "You just charged it fully"),
                ("It Ran Out, Now Charged", "It went flat before you charged it; this teaches the estimate"),
                ("Undo Last Mark", "Takes back a mistaken click"),
                ("Stop Estimating…", "Removes its charge marks and the use counted on this Mac"),
            ]),
            .tip("With iCloud Drive on, every Mac running BatteryLens adds its typing time to the same estimate, so a keyboard you move between Macs stays right. Use on an iPad or another computer can't be counted; turn Report this device off there instead."),
            .text("Counting use needs Input Monitoring (Settings › Permissions)."),
        ]),

        HelpTopic(id: "history", title: "History and Time Left", symbol: "chart.xyaxis.line", blocks: [
            .text("Settings › Devices shows a chart of each device's level over the last day, week or month. Green shading marks charging; the dashed line is its low-battery level."),
            .text("Once there's enough history, BatteryLens also says how long a battery should last, or how soon it will be full:"),
            .keys([
                ("Your Mac", "macOS's own estimate. None while it's plugged in and not charging"),
                ("Devices that report a level", "From how fast the current charge is going down, once it has dropped 5% over at least an hour; until then, from your recent charges"),
                ("Estimated devices", "The hours of use left, spread over how much you've used it each day lately. Needs a day of use first"),
            ]),
            .text("The time left shows in the menu bar menu, beside the device in the bars widget, and above the chart."),
        ]),

        HelpTopic(id: "alerts", title: "Alerts", symbol: "bell", blocks: [
            .text("BatteryLens can send a notification when a battery runs low, once per discharge. It warns again only after the device has been charged."),
            .keys([
                ("Low battery level", "The default level for every device: 20% unless you change it. A device can have its own in Settings › Devices"),
                ("Fully charged", "Optional: a notification when a charging device reaches 100%"),
            ]),
            .text("Earbud charging cases and the Mac itself are left out; macOS already warns about the Mac's own battery."),
            .tip("Click an alert to open that device's settings."),
        ]),

        HelpTopic(id: "menu-bar", title: "Menu Bar", symbol: "menubar.rectangle", blocks: [
            .text("The menu bar icon shows the lowest battery among connected devices (earbud cases excepted), or one device you choose in Settings › Menu Bar. The percentage next to it can be turned off."),
            .text("To hide the icon, or show BatteryLens in the Dock instead, use Settings › General. With both off, BatteryLens keeps running with no icon; open it again from Applications or Spotlight to get back to Settings."),
            .keys([
                ("⌘,", "Settings, from the menu"),
                ("⌘R", "Refresh Now: reads every source again"),
            ]),
        ]),

        HelpTopic(id: "permissions", title: "Permissions", symbol: "lock.shield", blocks: [
            .text("Every permission is optional. Without any, BatteryLens still shows your Mac, AirPods and most Apple and Bluetooth accessories."),
            .keys([
                ("Bluetooth", "Reads the standard battery level many Bluetooth mice, keyboards and headphones report"),
                ("Input Monitoring", "Reads Logitech devices and keyboards that send their battery with their input, and counts use for estimates. BatteryLens never reads what you type"),
                ("Notifications", "For low-battery and fully-charged alerts, and update news"),
            ]),
            .tip("If Input Monitoring is on in System Settings but BatteryLens still says it's off, turn it off and on again there, then quit and reopen BatteryLens."),
        ]),

        HelpTopic(id: "sync", title: "Sync and Updates", symbol: "icloud", blocks: [
            .text("Turn on Sync settings with your other Macs in Settings › General to keep the appearance, alerts, menu bar choices, update choice, asking before quitting and where BatteryLens appears the same on every Mac signed in to your iCloud account. Device names and per-device settings, and Open at login, stay separate on each Mac."),
            .heading("Updates"),
            .keys([
                ("Install automatically", "A new version installs itself when no app is presenting or keeping the screen awake and your Mac hasn't been used for 2 minutes"),
                ("Ask me first", "A notification says when a new version is out; nothing installs until you choose to"),
                ("Don't check", "BatteryLens never looks on its own; use Check Now"),
            ]),
            .text("Choose how often it looks under Check every, or check any time from the menu or Settings › General."),
            .heading("What's new"),
            .text("The update window shows the notes for the latest releases, with the ones you don't have yet marked New. \"Don't remind me about this version\" is ticked to begin with: click Not Now with it ticked, and BatteryLens stops reminding you about that version (Check Now still offers it). Untick it to be reminded again."),
            .text("After an update that installed itself, Settings shows what changed the next time it opens. Tick \"Don't show this again\" to put it away. What's New… beside Check Now in Settings › General shows the notes any time."),
            .tip("Settings can be dragged bigger to see more of a tab at once, and keeps the size you choose."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "link", blocks: [
            .text("Shortcuts, scripts and ToolHUD can control BatteryLens with batterylens:// links:"),
            .keys([
                ("batterylens://menu", "Shows the battery menu: under the menu bar icon, or at the pointer when the icon is hidden"),
                ("batterylens://refresh", "Reads every source again"),
                ("batterylens://devices", "Opens Settings › Devices, with each device's history and time left"),
                ("batterylens://settings", "Opens Settings"),
                ("batterylens://help", "Opens this Help"),
                ("batterylens://check-updates", "Looks for a new version now"),
            ]),
            .text("ToolHUD offers the first four as buttons: Batteries, Refresh, Devices and Settings."),
            .tip("In Terminal: open batterylens://refresh"),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("A device is missing"),
            .text("Make sure it's connected and switched on. Some devices only show up with Bluetooth or Input Monitoring allowed (Settings › Permissions). A device that reports no level at all can still be estimated."),
            .heading("The widget looks out of date"),
            .text("macOS decides when widgets refresh. The line at the bottom says how old the levels are; the menu bar menu is always current. After an update, a widget can take a few minutes to pick up the new version; if it stays blank, remove it and add it again."),
            .heading("Diagnostics"),
            .text("The menu bar menu's Diagnostics submenu shows what each source reads and the widget's recent activity, which helps when reporting a problem."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("BatteryLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
