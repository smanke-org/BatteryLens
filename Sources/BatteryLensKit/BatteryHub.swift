import BatteryLensShared
import Foundation

/// Runs every source, merges their readings into devices, folds those into the store
/// (remembered devices, settings) and the charge history, and publishes the result.
public final class BatteryHub {
    public let sources: [BatterySource]
    public let store: DeviceStore
    public let history: ChargeHistory
    public private(set) var readings: [SourceKind: [BatteryReading]] = [:]
    /// Every device, including disconnected and hidden ones, with settings applied.
    public private(set) var allDevices: [DeviceBattery] = []
    /// The ones the widget and the menu bar summary show.
    public var devices: [DeviceBattery] { store.visible(allDevices) }
    /// Called on the main thread with the visible devices, at most a few times a second.
    public var onChange: (([DeviceBattery]) -> Void)?
    private var recomputeScheduled = false

    public init(sources: [BatterySource] = BatteryHub.defaultSources(), store: DeviceStore = DeviceStore(),
                history: ChargeHistory = ChargeHistory()) {
        self.sources = sources
        self.store = store
        self.history = history
    }

    public static func defaultSources() -> [BatterySource] {
        [PowerSourceMonitor(), BluetoothProfilerMonitor(), BLEBatteryMonitor(), LogitechMonitor(),
         HIDBatteryMonitor(), ControllerMonitor(), EstimateSource()]
    }

    /// Which sources ask for a permission when they start, so onboarding can explain it first.
    public static let bluetoothSources: Set<SourceKind> = [.ble]
    public static let inputMonitoringSources: Set<SourceKind> = [.logitech, .hid, .estimate]

    /// The estimate source, for marking devices charged.
    public var estimates: EstimateSource? { sources.lazy.compactMap { $0 as? EstimateSource }.first }

    private var started = Set<SourceKind>()

    /// Starts every source except `held` ones, which wait for `start(_:)`.
    public func start(holding held: Set<SourceKind> = []) {
        start(Set(sources.map(\.kind)).subtracting(held))
    }

    /// Starts these sources if they haven't been started yet.
    public func start(_ kinds: Set<SourceKind>) {
        for source in sources where kinds.contains(source.kind) && !started.contains(source.kind) {
            started.insert(source.kind)
            let kind = source.kind
            source.onReadings = { [weak self] readings in self?.receive(kind, readings) }
            source.start()
        }
    }

    public func isStarted(_ kind: SourceKind) -> Bool { started.contains(kind) }

    public func refresh() {
        sources.filter { started.contains($0.kind) }.forEach { $0.refresh() }
    }

    /// Settings changed: republish without waiting for a reading.
    public func recompute() {
        let live = DeviceMerger.merge(readings.values.flatMap { $0 }, knownIDs: &store.knownIDs)
        history.record(live)
        let now = Date()
        allDevices = store.update(with: live).map { device in
            var device = device
            device.forecast = forecast(for: device, now: now)
            return device
        }
        onChange?(devices)
    }

    /// When the device's battery runs out or is full: macOS's figure for the Mac, usual
    /// daily use for an estimated device, the charge history for the rest.
    func forecast(for device: DeviceBattery, now: Date) -> Forecast? {
        if device.levels.contains(where: { $0.source == .estimate }) {
            return estimates?.forecast(for: EstimateSource.key(for: device), now: now)
        }
        // On power and not charging, the Mac has no forecast, whatever its past drain.
        if device.keys.contains("mac:internal") { return Forecaster.systemForecast(now: now) }
        guard device.isConnected else { return nil }
        // The battery that matters: the lowest in use, as for alerts.
        let inUse = device.levels.filter { $0.part != .chargingCase }
        guard let level = (inUse.isEmpty ? device.levels : inUse).min(by: { $0.percent < $1.percent }) else { return nil }
        return Forecaster.forecast(history.samples(for: device.id, part: level.part), percent: level.percent,
                                   isCharging: level.isCharging, now: now)
    }

    private func receive(_ kind: SourceKind, _ newReadings: [BatteryReading]) {
        readings[kind] = newReadings
        guard !recomputeScheduled else { return }
        // Sources often report together (a device connecting shows up in several), so
        // changes are gathered for a moment before merging.
        recomputeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.recomputeScheduled = false
            self.recompute()
        }
    }
}
