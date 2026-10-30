import AppKit
import IOKit.hid
import BatteryLensKit
import BatteryLensShared

/// The menu bar item listing every device, Settings, onboarding, alerts, and diagnostics
/// for checking the sources and the widget.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hub = BatteryHub()
    private let publisher = SnapshotPublisher()
    private let notifier = Notifier()
    private lazy var model = AppModel(hub: hub)
    private lazy var settingsWindow = SettingsWindowController(model: model)
    private var onboarding: OnboardingWindowController?
    private lazy var alerts: AlertMonitor = {
        let monitor = AlertMonitor(fired: Set(AppSettings.defaults.stringArray(forKey: AppSettings.Key.alertsFired) ?? []))
        monitor.onFiredChange = { AppSettings.defaults.set(Array($0).sorted(), forKey: AppSettings.Key.alertsFired) }
        return monitor
    }()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.register()
        #if DEBUG
        // Pictures for the website from made-up devices; starts nothing and saves nothing.
        if let folder = ProcessInfo.processInfo.environment["BATTERYLENS_DEBUG_SHOTS"] {
            DebugShots.run(folder: folder)
            return
        }
        #endif
        SharedContainer.trimLog()
        SharedContainer.log("app: launched \(AppInfo.versionString)"
                            + (SharedContainer.url == nil ? " — App Group container unavailable" : ""))
        restartStaleWidget()
        setUpMainMenu()
        AppAppearance.start()

        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        Preferences.shared.onReload = { [weak self] in self?.model.reloadSettings() }
        SettingsSync.shared.start()
        UserDefaults.standard.set(true, forKey: "launchedBefore")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "battery.100percent", accessibilityDescription: "BatteryLens")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.isVisible = MenuHub.shared.showsOwnIcon
        // Hidden in Settings, or taken into ToolHUD's menu while ToolHUD runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem.isVisible = MenuHub.shared.showsOwnIcon }
        }
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in self?.statusItem.button?.image })

        hub.onChange = { [weak self] devices in
            guard let self else { return }
            self.publisher.publish(devices)
            self.model.devicesChanged()
            self.updateButton()
            for alert in self.alerts.check(devices, lowEnabled: self.model.lowAlerts, fullEnabled: self.model.fullAlerts) {
                SharedContainer.log("app: alert — \(alert.title)")
                self.notifier.post(alert)
            }
        }
        model.onMenuBarChange = { [weak self] in self?.updateButton() }
        notifier.onOpen = { [weak self] device in self?.openSettings(device: device) }

        // Estimates follow each device's "Report this device" switch and keep its name.
        if let estimates = hub.estimates {
            let store = hub.store
            estimates.isReporting = { key in store.settings(for: store.knownIDs[key] ?? key).isReporting }
            estimates.describe = { key in
                store.remembered[store.knownIDs[key] ?? key].map { ($0.name, $0.kind) }
            }
        }

        // Sources whose permission was never asked for wait, so macOS doesn't prompt
        // before onboarding has explained why; its Allow buttons start them.
        var held = Set<SourceKind>()
        for permission in Permission.allCases where permission.syncState == .notAsked { held.formUnion(permission.sources) }
        hub.start(holding: held)

        listenForWidgetRequests()

        if !AppSettings.defaults.bool(forKey: AppSettings.Key.onboardingDone) {
            let onboarding = OnboardingWindowController(model: model)
            onboarding.onFinish = { [weak self] in
                AppSettings.defaults.set(true, forKey: AppSettings.Key.onboardingDone)
                self?.onboarding = nil
            }
            self.onboarding = onboarding
            onboarding.show()
        }

        // Nothing BatteryLens does is hurt by a restart, so updates need no busy check.
        AutoUpdater.shared.start()
        if !AppPresence.showInMenuBar && !AppPresence.showInDock && onboarding == nil { openSettings() }

        // Once the sources have settled: which ones run and which wait for a permission.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            for source in self.hub.sources {
                let status = self.hub.isStarted(source.kind) ? source.status : "waiting for its permission"
                SharedContainer.logger.info("app: source \(source.kind.rawValue, privacy: .public): \(status, privacy: .public)")
            }
        }
    }

    /// The widget's buttons post a Darwin notification after queuing a request.
    private func listenForWidgetRequests() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.handleWidgetRequests() }
        }, WidgetRequests.notificationName as CFString, nil, .deliverImmediately)
        handleWidgetRequests()
    }

    private func handleWidgetRequests() {
        for request in WidgetRequests.take() {
            switch request.action {
            case .markCharged:
                guard let device = hub.allDevices.first(where: { $0.id == request.deviceID }) else { continue }
                model.markCharged(device, ranOut: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.store.saveIfNeeded(force: true)
        hub.estimates?.save()
    }

    /// Opening the app again (Finder, Spotlight, the Dock tile) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(openSettingsFromMenu))
    }

    /// `batterylens://` links, from ToolHUD, Shortcuts or a script.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "batterylens" {
            switch url.host {
            case "refresh": hub.refresh()
            case "help": showHelp()
            default: openSettings()
            }
        }
    }

    /// The widget extension keeps running the old version's code after an update until
    /// it's restarted; WidgetKit starts the new one the next time it needs the widget.
    private func restartStaleWidget() {
        let key = "lastLaunchedBuild"
        let build = AppInfo.versionString
        guard let last = UserDefaults.standard.string(forKey: key), last != build else {
            UserDefaults.standard.set(build, forKey: key)
            return
        }
        UserDefaults.standard.set(build, forKey: key)
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "BatteryLens.app/Contents/PlugIns/BatteryLensWidget.appex"]
        try? pkill.run()
        SharedContainer.log("app: updated from \(last); restarted the widget")
    }

    /// The app's own menu bar, shown while it has a Dock icon.
    private func setUpMainMenu() {
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(openSettingsFromMenu))
        // Right below About in the app menu, where Mac apps keep it.
        mainMenu.items.first?.submenu?.insertItem(action("Check for Updates…", #selector(checkForUpdates)), at: 1)
        mainMenu.items.first?.submenu?.insertItem(action("Our other apps…", #selector(showOtherApps)), at: 2)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(action("\(AppInfo.name) Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showHelp() { HelpWindow.shared.show() }
    @objc private func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc private func installUpdateNow() { AutoUpdater.shared.installNow() }

    /// The developer's site, which lists every app.
    @objc private func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// The chosen device's level, or the lowest among connected devices.
    private func updateButton() {
        let devices = hub.devices
        let level: Int?
        if !model.menuBarDevice.isEmpty, let device = devices.first(where: { $0.id == model.menuBarDevice }) {
            level = device.lowest
            statusItem.button?.toolTip = device.name
        } else {
            level = devices.filter(\.isConnected).compactMap(\.lowest).min()
            statusItem.button?.toolTip = "BatteryLens"
        }
        let symbol = switch level ?? 100 {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BatteryLens")
        statusItem.button?.title = model.menuBarShowsPercent ? level.map { " \($0)%" } ?? "" : ""
    }

    @objc private func openSettingsFromMenu() { openSettings() }

    private func openSettings(device: String? = nil) {
        if let device {
            model.selectedDevice = device
            settingsWindow.show(tab: .devices)
        } else {
            settingsWindow.show()
        }
    }

    @objc private func openDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openSettings(device: id)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("BatteryLens \(AppInfo.displayVersion)"))
        menu.addItem(.separator())

        if hub.devices.isEmpty { menu.addItem(disabled("Looking for devices…")) }
        for device in hub.devices { menu.addItem(item(for: device)) }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        diagnosticsMenu.autoenablesItems = false
        diagnosticsMenu.addItem(sourcesMenu())
        diagnosticsMenu.addItem(widgetMenu())
        diagnostics.submenu = diagnosticsMenu
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        let help = action("\(AppInfo.name) Help", #selector(showHelp))
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(help)
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(action("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(action("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(action("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(action("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BatteryLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(for device: DeviceBattery) -> NSMenuItem {
        var text = device.name + "    " + levelText(device)
        if !device.isConnected { text += " · \(device.updated.formatted(.relative(presentation: .named)))" }
        if let forecast = device.forecast { text += " · " + forecast.shortText() }
        let item = NSMenuItem(title: text, action: #selector(openDevice(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.id
        item.image = NSImage(systemSymbolName: device.kind.symbol, accessibilityDescription: nil)
        if !device.isConnected {
            item.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        item.toolTip = device.levels.map { "\($0.part?.shortName ?? "Battery"): \($0.percent)% from \($0.source.displayName)" }
            .joined(separator: "\n")
        return item
    }

    private func levelText(_ device: DeviceBattery) -> String {
        guard !device.levels.isEmpty else { return "no level" }
        let parts = device.levels.map { level in
            (level.part.map { "\($0.shortName) " } ?? "") + (level.source == .estimate ? "~" : "") + "\(level.percent)%"
                + (level.isCharging ? " ⚡︎" : "")
        }
        return parts.joined(separator: "  ")
    }

    /// Every source's status and raw readings, for checking what each one sees.
    private func sourcesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Readings by Source", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for source in hub.sources {
            let status = hub.isStarted(source.kind) ? source.status : "waiting for its permission"
            submenu.addItem(disabled("\(source.kind.displayName): \(status)"))
            for reading in hub.readings[source.kind] ?? [] {
                let level = reading.percent.map { "\($0)%" } ?? "—"
                let part = reading.part.map { " (\($0.shortName))" } ?? ""
                submenu.addItem(disabled("    \(reading.name)\(part)  \(level)  [\(reading.keys.sorted().joined(separator: ", "))]"))
            }
        }
        item.submenu = submenu
        return item
    }

    /// When the app asked the widget to reload, and when WidgetKit actually ran it.
    private func widgetMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Widget Activity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let lines = SharedContainer.logLines()
        let today = Calendar.current.startOfDay(for: Date())
        let todayPrefix = today.formatted(.iso8601.year().month().day())
        let todays = lines.filter { $0.hasPrefix(todayPrefix) }
        submenu.addItem(disabled("Today: \(todays.filter { $0.contains("app: asked widget") }.count) reloads asked, "
                                 + "\(todays.filter { $0.contains("widget: timeline") }.count) timelines served"))
        submenu.addItem(.separator())
        for line in lines.suffix(25).reversed() { submenu.addItem(disabled(line)) }
        submenu.addItem(.separator())
        let reveal = NSMenuItem(title: "Show Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        reveal.target = self
        submenu.addItem(reveal)
        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func refreshNow() {
        hub.refresh()
    }

    @objc private func revealLog() {
        guard let url = SharedContainer.logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}


