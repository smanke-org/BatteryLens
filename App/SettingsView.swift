import AppKit
import BatteryLensKit
import BatteryLensShared
import SwiftUI

/// The Settings tabs, so the window can be sized to the one showing.
enum SettingsTab: Hashable, CaseIterable {
    case general, devices, alerts, menuBar, permissions
}

final class SettingsTabState: ObservableObject {
    @Published var tab: SettingsTab = .devices
}

struct SettingsView: View {
    static let width: CGFloat = 620

    @ObservedObject var model: AppModel
    @ObservedObject var tabState: SettingsTabState

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tabState.tab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    content(tab)
                        .tabItem { label(tab) }
                        .tag(tab)
                }
            }
            footer(tabState.tab)
        }
        .padding(12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    /// One tab on its own, for measuring its natural height. A one-tab TabView has the
    /// same tab bar and padding as the real one.
    func measuring(_ tab: SettingsTab) -> some View {
        VStack(spacing: 0) {
            TabView { content(tab, measuring: true).tabItem { label(tab) } }
            footer(tab)
        }
        .padding(12)
        .frame(width: Self.width)
    }

    /// The tab's Help button.
    private func footer(_ tab: SettingsTab) -> some View {
        HStack {
            Spacer()
            HelpButton(topic: Help.topic(forSettingsTab: tab)).fixedSize()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab, measuring: Bool = false) -> some View {
        switch tab {
        // The device list scrolls on its own, so its tab has a set height.
        case .general: scrolling(measuring) { GeneralTab() }
        case .devices: DevicesTab(model: model).frame(height: 420)
        case .alerts: scrolling(measuring) { AlertsTab(model: model) }
        case .menuBar: scrolling(measuring) { MenuBarTab(model: model) }
        case .permissions: scrolling(measuring) { PermissionsTab(model: model) }
        }
    }

    /// Each tab scrolls when the window, which is capped to the screen, is shorter than it.
    @ViewBuilder
    private func scrolling<Content: View>(_ measuring: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        let page = content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        if measuring { page } else { ScrollView { page } }
    }

    private func label(_ tab: SettingsTab) -> Label<Text, Image> {
        switch tab {
        case .general: Label("General", systemImage: "gearshape")
        case .devices: Label("Devices", systemImage: "battery.75percent")
        case .alerts: Label("Alerts", systemImage: "bell")
        case .menuBar: Label("Menu Bar", systemImage: "menubar.rectangle")
        case .permissions: Label("Permissions", systemImage: "lock.shield")
        }
    }
}

// MARK: - Devices

struct DevicesTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedDevice) {
                ForEach(model.devices) { device in
                    DeviceListRow(device: device, settings: model.settings(for: device.id))
                        .tag(Optional(device.id))
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider()

            Group {
                if let id = model.selectedDevice, let device = model.devices.first(where: { $0.id == id }) {
                    DeviceDetail(model: model, device: device).id(device.id)
                } else {
                    Text(model.devices.isEmpty ? "No devices yet" : "Select a device")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.selectedDevice == nil { model.selectedDevice = model.devices.first?.id }
        }
    }
}

struct DeviceListRow: View {
    let device: DeviceBattery
    let settings: DeviceSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.kind.symbol)
                .frame(width: 18)
            Text(device.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if settings.isHidden || !settings.isReporting {
                Image(systemName: settings.isReporting ? "eye.slash" : "nosign")
                    .foregroundStyle(.secondary)
                    .help(settings.isReporting ? "Hidden" : "Not reported")
            }
            Text(device.lowest.map { "\($0)%" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(device.isConnected ? 1 : 0.55)
    }
}

struct DeviceDetail: View {
    @ObservedObject var model: AppModel
    let device: DeviceBattery
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var confirmForget = false

    private var settings: DeviceSettings { model.settings(for: device.id) }
    private var originalName: String { model.remembered(device.id)?.name ?? device.name }

    private static let thresholds = [5, 10, 15, 20, 25, 30, 40, 50]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: device.kind.symbol)
                        .font(.title)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.title3.weight(.semibold))
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.callout.weight(.medium))
                    TextField("Name", text: $name, prompt: Text(originalName))
                        .labelsHidden()
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Report this device", isOn: binding(\.isReporting))
                    Text("Turn this off for a keyboard or mouse you share with another computer. BatteryLens then leaves it out of the widget, the menu bar, alerts and estimates, and stops counting your use of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show in the widget and menu bar", isOn: Binding(
                    get: { !settings.isHidden },
                    set: { show in model.update(device.id) { $0.isHidden = !show } }))
                    .disabled(!settings.isReporting)

                Picker("Low battery alert at", selection: Binding(
                    get: { settings.lowThreshold },
                    set: { value in model.update(device.id) { $0.lowThreshold = value } })) {
                    Text("Default (\(model.defaultLowThreshold)%)").tag(Int?.none)
                    Divider()
                    ForEach(Self.thresholds, id: \.self) { Text("\($0)%").tag(Int?.some($0)) }
                }
                .fixedSize()
                .disabled(!settings.isReporting)

                if model.canEstimate(device) && settings.isReporting {
                    Divider()
                    EstimateSection(model: model, device: device)
                }

                if !device.levels.isEmpty {
                    Divider()
                    HistorySection(model: model, device: device)
                }

                Divider()

                details

                HStack {
                    Spacer()
                    Button("Forget Device…") { confirmForget = true }
                        .disabled(device.isConnected)
                        .help(device.isConnected ? "Only a disconnected device can be forgotten." : "")
                }
            }
            .padding(20)
        }
        .onAppear { name = settings.customName ?? "" }
        .onDisappear(perform: commitName)
        .confirmationDialog("Forget \(device.name)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { model.forget(device.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings and last-known levels are removed. If it connects again, it comes back as a new device.")
        }
    }

    private var status: String {
        var parts: [String] = []
        if device.levels.isEmpty {
            parts.append("No battery level reported")
        } else {
            parts.append(device.levels.map { level in
                (level.part.map { "\($0 == .chargingCase ? "Case" : $0 == .left ? "Left" : "Right") " } ?? "")
                    + "\(level.percent)%" + (level.isCharging ? " charging" : "")
            }.joined(separator: ", "))
        }
        if !device.isConnected {
            parts.append("not connected, seen \(device.updated.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.callout.weight(.medium))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Read from").foregroundStyle(.secondary)
                    Text(sources)
                }
                if let remembered = model.remembered(device.id) {
                    GridRow {
                        Text("First seen").foregroundStyle(.secondary)
                        Text(remembered.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                GridRow {
                    Text("Identifiers").foregroundStyle(.secondary)
                    Text(device.keys.sorted().joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
        }
    }

    private var sources: String {
        let names = Set(device.levels.map(\.source)).sorted().map(\.displayName)
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    private func binding(_ keyPath: WritableKeyPath<DeviceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { value in model.update(device.id) { $0[keyPath: keyPath] = value } })
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        model.update(device.id) { $0.customName = trimmed.isEmpty || trimmed == originalName ? nil : trimmed }
    }
}

// MARK: - Estimate

/// For a device that never reports its battery: start, reset and teach the estimate.
struct EstimateSection: View {
    @ObservedObject var model: AppModel
    let device: DeviceBattery
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated Battery").font(.callout.weight(.medium))
            if let estimate = model.estimate(for: device) {
                Text("About \(estimate.percent)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(summary(estimate))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Mark as Charged") { model.markCharged(device, ranOut: false) }
                        .help("You just charged it fully.")
                    Button("It Ran Out, Now Charged") { model.markCharged(device, ranOut: true) }
                        .help("It went flat before you charged it, which teaches BatteryLens how long a charge lasts.")
                    Spacer()
                    Menu {
                        Button("Undo Last Mark") { model.undoLastMark(device) }
                        Button("Stop Estimating…") { confirmStop = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Text("This device doesn't report its battery. BatteryLens can estimate it from how much you use it: charge it fully, then click Mark as Charged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Mark as Charged") { model.markCharged(device, ranOut: false) }
                if model.permissions[.inputMonitoring] != .granted {
                    Text("Counting use needs Input Monitoring (Settings › Permissions).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .confirmationDialog("Stop estimating \(device.name)?", isPresented: $confirmStop) {
            Button("Stop Estimating", role: .destructive) { model.stopEstimating(device) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its charge marks and the use counted on this Mac are removed.")
        }
    }

    private func summary(_ estimate: Estimator.Estimate) -> String {
        let used = estimate.activeMinutes < 60
            ? "\(estimate.activeMinutes) min" : String(format: "%.1f h", Double(estimate.activeMinutes) / 60)
        let since = estimate.chargedAt.formatted(date: .abbreviated, time: .shortened)
        let lasts = estimate.learnedFrom == 0
            ? "A charge is assumed to last about \(Int(estimate.hoursPerCharge)) hours of use until it runs out once; then click It Ran Out, Now Charged and BatteryLens learns the real figure."
            : "A charge lasts about \(Int(estimate.hoursPerCharge.rounded())) hours of use, learned from \(estimate.learnedFrom) charge\(estimate.learnedFrom == 1 ? "" : "s")."
        let macs = model.estimatesSync ? " Use on your other Macs running BatteryLens counts too." : ""
        return "\(used) of use since you charged it on \(since). \(lasts)\(macs)"
    }
}

// MARK: - Alerts

struct AlertsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Tell me when a battery is low", isOn: $model.lowAlerts)
                Picker("Low battery level", selection: $model.defaultLowThreshold) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                .fixedSize()
                .padding(.leading, 20)
                Text("Once per discharge. A device can have its own level in Devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            Toggle("Tell me when a battery is fully charged", isOn: $model.fullAlerts)
            Text("Earbud charging cases and this Mac are left out; macOS already warns about the Mac's own battery.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.permissions[.notifications] != .granted {
                Divider()
                PermissionRow(model: model, permission: .notifications)
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Menu bar shows", selection: $model.menuBarDevice) {
                Text("The lowest battery").tag("")
                Divider()
                ForEach(model.hub.devices) { device in
                    Label(device.name, systemImage: device.kind.symbol).tag(device.id)
                }
                // A chosen device that's hidden or gone stays selectable so the picker isn't blank.
                if !model.menuBarDevice.isEmpty, !model.hub.devices.contains(where: { $0.id == model.menuBarDevice }) {
                    Text(model.devices.first { $0.id == model.menuBarDevice }?.name ?? "Unknown device").tag(model.menuBarDevice)
                }
            }
            .fixedSize()
            Toggle("Show the percentage next to the icon", isOn: $model.menuBarShowsPercent)
            Text("The lowest battery counts connected devices that report a level, earbud cases excepted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Every permission is optional. Without them BatteryLens still shows your Mac, AirPods and most Apple and Bluetooth LE accessories.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Permission.allCases) { permission in
                PermissionRow(model: model, permission: permission)
                if permission != Permission.allCases.last { Divider() }
            }
        }
    }
}

struct PermissionRow: View {
    @ObservedObject var model: AppModel
    let permission: Permission

    private var state: Permission.State { model.permissions[permission] ?? .notAsked }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    stateBadge
                }
                Text(permission.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .denied {
                    Text(permission == .inputMonitoring
                         ? "Turn BatteryLens on in System Settings › Privacy & Security › Input Monitoring. If it's already on, turn it off and on again."
                         : "Turn it on for BatteryLens in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .granted: EmptyView()
            case .notAsked: Button("Allow…") { model.request(permission) }
            case .denied: Button("Open System Settings") { model.request(permission) }
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied: Label("Off", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
        case .notAsked: Label("Not set up", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
