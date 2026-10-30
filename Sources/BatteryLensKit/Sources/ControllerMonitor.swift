import BatteryLensShared
import Foundation
import GameController

/// Game controllers (Xbox, PlayStation, Switch) report their battery through
/// GameController. Needs no permission.
public final class ControllerMonitor: BatterySource {
    public let kind = SourceKind.controller
    public private(set) var status = "not started"
    public var onReadings: (([BatteryReading]) -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        // A menu bar app is never frontmost, so it has to ask to hear about controllers.
        GCController.shouldMonitorBackgroundEvents = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        let controllers = GCController.controllers()
        let readings = controllers.compactMap { controller -> BatteryReading? in
            guard let battery = controller.battery else { return nil }
            let name = controller.vendorName ?? controller.productCategory
            return BatteryReading(keys: ["gc:\(name)-\(ObjectIdentifier(controller).hashValue)"], name: name, kind: .controller,
                                  percent: Int((battery.batteryLevel * 100).rounded()),
                                  isCharging: battery.batteryState == .charging, source: .controller)
        }
        status = "\(controllers.count) controllers"
        onReadings?(readings)
    }
}
