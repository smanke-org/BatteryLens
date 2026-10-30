import AppKit
import BatteryLensKit
import BatteryLensShared
import Combine
import CoreBluetooth
import IOKit.hid
import UserNotifications

/// App-wide choices, in UserDefaults.
enum AppSettings {
    static let defaults = UserDefaults.standard

    enum Key {
        static let lowAlerts = "lowAlerts"
        static let fullAlerts = "fullAlerts"
        static let defaultLowThreshold = "defaultLowThreshold"
        static let menuBarDevice = "menuBarDevice"
        static let menuBarShowsPercent = "menuBarShowsPercent"
        static let onboardingDone = "onboardingDone"
        static let alertsFired = "alertsFired"
        static let confirmQuit = "confirmQuit"
    }

    static func register() {
        defaults.register(defaults: [
            Key.lowAlerts: true,
            Key.fullAlerts: false,
            Key.defaultLowThreshold: DeviceBattery.defaultLowThreshold,
            Key.menuBarDevice: "",
            Key.menuBarShowsPercent: true,
            Key.confirmQuit: true,
            // Unlike the other apps' icons, this one shows a level, which a submenu in
            // ToolHUD's menu can't, so it stays in the menu bar unless asked.
            MenuHub.foldKey: false,
        ])
    }
}

/// The permissions BatteryLens can use. Every one is optional.
enum Permission: CaseIterable, Identifiable {
    case bluetooth, inputMonitoring, notifications

    var id: Self { self }

    enum State { case granted, denied, notAsked }

    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .inputMonitoring: "Input Monitoring"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .inputMonitoring: "keyboard"
        case .notifications: "bell.badge"
        }
    }

    var explanation: String {
        switch self {
        case .bluetooth:
            "Reads the standard battery level many Bluetooth mice, keyboards and headphones report."
        case .inputMonitoring:
            "Reads exact levels from Logitech devices and from keyboards and mice that send their battery with their input. BatteryLens never reads what you type."
        case .notifications:
            "Lets BatteryLens tell you when a battery is low, or fully charged if you turn that on."
        }
    }

    var settingsURL: URL {
        switch self {
        case .bluetooth: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        case .inputMonitoring: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
        }
    }

    /// The sources that wait for this permission.
    var sources: Set<SourceKind> {
        switch self {
        case .bluetooth: BatteryHub.bluetoothSources
        case .inputMonitoring: BatteryHub.inputMonitoringSources
        case .notifications: []
        }
    }

    /// The current state, except notifications, which are only known asynchronously.
    var syncState: State? {
        switch self {
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .notAsked
            }
        case .notifications: nil
        }
    }
}

/// What the Settings window and onboarding show and change.
@MainActor
final class AppModel: ObservableObject {
    let hub: BatteryHub
    /// Every device, including hidden and disconnected ones.
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var permissions: [Permission: Permission.State] = [:]
    /// Settings › Devices shows this one; set when a device is clicked in the menu.
    @Published var selectedDevice: String?

    @Published var lowAlerts = AppSettings.defaults.bool(forKey: AppSettings.Key.lowAlerts) {
        didSet { AppSettings.defaults.set(lowAlerts, forKey: AppSettings.Key.lowAlerts)
            if lowAlerts != oldValue { syncChanged() } }
    }
    @Published var fullAlerts = AppSettings.defaults.bool(forKey: AppSettings.Key.fullAlerts) {
        didSet {
            AppSettings.defaults.set(fullAlerts, forKey: AppSettings.Key.fullAlerts)
            if fullAlerts != oldValue { syncChanged() }
            if fullAlerts { request(.notifications) }
        }
    }
    @Published var defaultLowThreshold = AppSettings.defaults.integer(forKey: AppSettings.Key.defaultLowThreshold) {
        didSet {
            AppSettings.defaults.set(defaultLowThreshold, forKey: AppSettings.Key.defaultLowThreshold)
            if defaultLowThreshold != oldValue { syncChanged() }
            hub.store.defaultLowThreshold = defaultLowThreshold
            hub.recompute()
        }
    }
    @Published var menuBarDevice = AppSettings.defaults.string(forKey: AppSettings.Key.menuBarDevice) ?? "" {
        didSet {
            AppSettings.defaults.set(menuBarDevice, forKey: AppSettings.Key.menuBarDevice)
            onMenuBarChange?()
        }
    }
    @Published var menuBarShowsPercent = AppSettings.defaults.bool(forKey: AppSettings.Key.menuBarShowsPercent) {
        didSet {
            AppSettings.defaults.set(menuBarShowsPercent, forKey: AppSettings.Key.menuBarShowsPercent)
            if menuBarShowsPercent != oldValue { syncChanged() }
            onMenuBarChange?()
        }
    }

    /// Quitting asks first, so a stray ⌘Q doesn't stop the widget and alerts.
    @Published var confirmQuit = AppSettings.defaults.bool(forKey: AppSettings.Key.confirmQuit) {
        didSet {
            AppSettings.defaults.set(confirmQuit, forKey: AppSettings.Key.confirmQuit)
            if confirmQuit != oldValue { syncChanged() }
        }
    }

    var onMenuBarChange: (() -> Void)?
    private var permissionTimer: Timer?
    private var reloadingSettings = false

    /// A synced setting changed here: tell settings sync, unless it's another Mac's
    /// value being applied.
    private func syncChanged() {
        if !reloadingSettings { SettingsSync.shared.localDidChange() }
    }

    /// Settings from another Mac were written into UserDefaults.
    func reloadSettings() {
        reloadingSettings = true
        defer { reloadingSettings = false }
        let defaults = AppSettings.defaults
        if lowAlerts != defaults.bool(forKey: AppSettings.Key.lowAlerts) { lowAlerts.toggle() }
        if fullAlerts != defaults.bool(forKey: AppSettings.Key.fullAlerts) { fullAlerts.toggle() }
        let threshold = defaults.integer(forKey: AppSettings.Key.defaultLowThreshold)
        if defaultLowThreshold != threshold { defaultLowThreshold = threshold }
        let percent = defaults.bool(forKey: AppSettings.Key.menuBarShowsPercent)
        if menuBarShowsPercent != percent { menuBarShowsPercent = percent }
        if confirmQuit != defaults.bool(forKey: AppSettings.Key.confirmQuit) { confirmQuit.toggle() }
    }

    init(hub: BatteryHub) {
        self.hub = hub
        hub.store.defaultLowThreshold = defaultLowThreshold
        refreshPermissions()
    }

    func devicesChanged() {
        devices = hub.allDevices
    }

    // MARK: - Devices

    func settings(for id: String) -> DeviceSettings { hub.store.settings(for: id) }

    func update(_ id: String, _ change: (inout DeviceSettings) -> Void) {
        var settings = hub.store.settings(for: id)
        change(&settings)
        guard settings != hub.store.settings(for: id) else { return }
        hub.store.setSettings(settings, for: id)
        hub.recompute()
    }

    func remembered(_ id: String) -> RememberedDevice? { hub.store.remembered[id] }

    func history(for device: DeviceBattery) -> [ChargeHistory.Sample] { hub.history.samples(for: device.id) }

    func forget(_ id: String) {
        hub.store.forget(id)
        hub.store.saveIfNeeded(force: true)
        if selectedDevice == id { selectedDevice = nil }
        hub.recompute()
    }

    // MARK: - Estimates

    func estimateKey(_ device: DeviceBattery) -> String { EstimateSource.key(for: device) }

    /// Devices that report no level of their own can be estimated.
    func canEstimate(_ device: DeviceBattery) -> Bool {
        device.kind != .mac && !device.levels.contains { $0.source != .estimate }
    }

    func estimate(for device: DeviceBattery) -> Estimator.Estimate? {
        hub.estimates?.estimate(for: estimateKey(device))
    }

    var estimatesSync: Bool { hub.estimates?.isSyncing == true }

    func markCharged(_ device: DeviceBattery, ranOut: Bool) {
        hub.estimates?.markCharged(estimateKey(device), ranOut: ranOut)
        // Counting needs Input Monitoring; ask now if it never was.
        if permissions[.inputMonitoring] == .notAsked { request(.inputMonitoring) }
    }

    func undoLastMark(_ device: DeviceBattery) { hub.estimates?.undoLastMark(estimateKey(device)) }

    func stopEstimating(_ device: DeviceBattery) { hub.estimates?.stopEstimating(estimateKey(device)) }

    // MARK: - Permissions

    func refreshPermissions() {
        for permission in Permission.allCases {
            if let state = permission.syncState { set(permission, state) }
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: Permission.State = switch settings.authorizationStatus {
            case .authorized, .provisional: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
            DispatchQueue.main.async { self.set(.notifications, state) }
        }
    }

    private func set(_ permission: Permission, _ state: Permission.State) {
        let old = permissions[permission]
        if old != state { permissions[permission] = state }
        // Allowed in System Settings while running: start (or retry) its sources now.
        if state == .granted, old != .granted, !permission.sources.isEmpty {
            hub.start(permission.sources)
            hub.refresh()
        }
    }

    /// Asks for a permission the first time; once refused, only System Settings can change it.
    func request(_ permission: Permission) {
        switch permissions[permission] ?? .notAsked {
        case .granted: return
        case .denied: NSWorkspace.shared.open(permission.settingsURL)
        case .notAsked:
            switch permission {
            case .bluetooth:
                // Creating the Bluetooth source's CBCentralManager is what shows the prompt.
                hub.start(permission.sources)
            case .inputMonitoring:
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                hub.start(permission.sources)
            case .notifications:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    DispatchQueue.main.async { self.refreshPermissions() }
                }
            }
        }
        refreshPermissions()
    }

    /// Permissions change in System Settings, so they're polled while a window shows them.
    func watchPermissions(_ watching: Bool) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard watching else { return }
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }
}
