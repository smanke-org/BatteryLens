import SwiftUI

/// Appearance, where BatteryLens appears, login, iCloud sync and updates.
struct GeneralTab: View {
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared
    @State private var login = LaunchAtLogin.shared
    @State private var sync = SettingsSync.shared
    @State private var updater = AutoUpdater.shared

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            "BatteryLens checks \(updater.interval.phrase). A new version installs itself when no app is presenting or keeping the screen awake and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "BatteryLens checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "BatteryLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                AppearancePicker { SettingsSync.shared.localDidChange() }
                    .fixedSize()
                note(AppAppearance.footer(appName: "BatteryLens"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Where BatteryLens appears").font(.callout.weight(.medium))
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows this menu as a submenu of its own, and BatteryLens’s icon leaves the menu bar until ToolHUD quits.")
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "BatteryLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                note("The widget shows either way.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open BatteryLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    HStack {
                        Group {
                            if let error = sync.lastError {
                                Text(error).foregroundStyle(.red)
                            } else if let date = sync.lastSynced {
                                Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                            } else {
                                Text("Waiting for iCloud Drive…")
                            }
                        }
                        .font(.callout)
                        Spacer()
                        Button("Sync Now") { sync.syncNow() }
                    }
                }
                note("Appearance, alerts, the menu bar percentage, the update choice and where BatteryLens appears follow you to every Mac signed in to the same iCloud account with sync on. Device names and settings, and Open at login, stay on each Mac.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                        .fixedSize()
                }
                if let staged = updater.staged {
                    HStack {
                        Text("Version \(staged.version) is ready")
                        Button("Install Now") { updater.installNow() }
                    }
                }
                HStack {
                    Text("Version \(AppInfo.displayVersion)")
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    HStack {
                        Label("Notifications are off for BatteryLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    }
                    .font(.callout)
                }
                note(updateFooter)
            }
        }
        .onAppear { login.refresh(); updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
