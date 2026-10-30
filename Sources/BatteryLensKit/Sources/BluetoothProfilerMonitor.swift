import BatteryLensShared
import Foundation

/// What System Information knows about Bluetooth devices: AirPods and Beats left, right
/// and case levels (kept after they disconnect), and which battery-powered devices are
/// connected even when they report no level. Takes a fraction of a second, so it runs in
/// the background every few minutes.
public final class BluetoothProfilerMonitor: BatterySource {
    public let kind = SourceKind.profiler
    public private(set) var status = "not started"
    public var onReadings: (([BatteryReading]) -> Void)?
    private var timer: Timer?
    private var running = false

    public init() {}

    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.runProfiler()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                guard let data else {
                    self.status = "system_profiler failed"
                    return
                }
                let readings = Self.readings(from: data)
                self.status = "\(readings.count) readings"
                self.onReadings?(readings)
            }
        }
    }

    private static func runProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func readings(from data: Data, now: Date = Date()) -> [BatteryReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var readings: [BatteryReading] = []
        for controller in controllers {
            for (group, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in controller[group] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        guard let properties = value as? [String: Any] else { continue }
                        readings += self.readings(name: name, properties: properties, connected: connected, now: now)
                    }
                }
            }
        }
        return readings
    }

    private static func readings(name: String, properties: [String: Any], connected: Bool, now: Date) -> [BatteryReading] {
        let keys: Set<String> = (properties["device_address"] as? String).flatMap(normalizedAddress).map { ["bt:\($0)"] } ?? []
        let kind: DeviceKind
        switch properties["device_minorType"] as? String {
        case "Mouse": kind = .mouse
        case "Keyboard": kind = .keyboard
        case "Trackpad": kind = .trackpad
        case "Headphones", "Headset": kind = .headphones
        case "Gamepad", "Joystick": kind = .controller
        default: kind = .other
        }

        let battery = properties.filter { $0.key.hasPrefix("device_batteryLevel") }
        guard !battery.isEmpty else {
            // A connected keyboard, mouse or headphones with no level is still worth
            // listing; speakers, TVs and the like are not.
            guard connected, kind != .other else { return [] }
            return [BatteryReading(keys: keys, name: name, kind: kind, percent: nil, isConnected: true,
                                   source: .profiler, date: now)]
        }
        return battery.compactMap { key, value in
            guard let percent = Int("\(value)".filter(\.isNumber)) else { return nil }
            let part: BatteryPart?
            switch key.replacingOccurrences(of: "device_batteryLevel", with: "") {
            case "Left": part = .left
            case "Right": part = .right
            case "Case": part = .chargingCase
            default: part = nil
            }
            return BatteryReading(keys: keys, name: name, kind: part == nil ? kind : .earbuds, part: part, percent: percent,
                                  isConnected: connected, source: .profiler, date: now)
        }
    }
}
