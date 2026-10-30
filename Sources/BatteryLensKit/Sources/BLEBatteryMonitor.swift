import BatteryLensShared
import CoreBluetooth
import Foundation

/// The standard Bluetooth LE Battery Service (0x180F) of devices the Mac is already
/// connected to: retrieved rather than scanned for, then read and subscribed to.
/// Needs the Bluetooth permission. The peripheral's identifier is the same UUID IOKit
/// uses, so these readings merge with the power list's and HID++'s.
public final class BLEBatteryMonitor: NSObject, BatterySource, CBCentralManagerDelegate, CBPeripheralDelegate {
    public let kind = SourceKind.ble
    public private(set) var status = "not started"
    public var onReadings: (([BatteryReading]) -> Void)?

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    /// HID and Device Information too: some devices hide 0x180F from retrieval but still
    /// offer it once connected.
    private lazy var retrievalServices = [[batteryService], [CBUUID(string: "1812")], [CBUUID(string: "180A")]]

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Latest level per battery characteristic, per device.
    private var levels: [UUID: [ObjectIdentifier: (Int, Date)]] = [:]
    private var timer: Timer?

    public override init() {}

    public func start() {
        status = switch CBManager.authorization {
        case .notDetermined: "waiting for the Bluetooth permission"
        case .denied, .restricted: "Bluetooth permission not given"
        default: "starting"
        }
        central = CBCentralManager(delegate: self, queue: nil)
        // There's no notification for a device connecting, so look again regularly.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.retrieve() }
    }

    public func refresh() {
        retrieve()
        for peripheral in peripherals.values where peripheral.state == .connected {
            for service in peripheral.services ?? [] where service.uuid == batteryService {
                for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevel {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    private func retrieve() {
        guard let central, central.state == .poweredOn else { return }
        var found: [UUID: CBPeripheral] = [:]
        for services in retrievalServices {
            for peripheral in central.retrieveConnectedPeripherals(withServices: services) {
                found[peripheral.identifier] = peripheral
            }
        }
        for (id, peripheral) in found where peripherals[id] == nil {
            peripherals[id] = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
        for id in peripherals.keys where found[id] == nil {
            peripherals[id] = nil
            levels[id] = nil
        }
        status = "\(peripherals.count) connected devices, \(levels.count) with a battery"
        emit()
    }

    private func emit() {
        let readings = levels.compactMap { id, values -> BatteryReading? in
            guard let peripheral = peripherals[id], let lowest = values.values.min(by: { $0.0 < $1.0 }) else { return nil }
            return BatteryReading(keys: ["uuid:\(id.uuidString)"], name: peripheral.name ?? "Bluetooth device", kind: .other,
                                  percent: min(100, lowest.0), source: .ble, date: lowest.1)
        }
        onReadings?(readings)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: retrieve()
        case .unauthorized: status = "Bluetooth permission not given"
        case .poweredOff: status = "Bluetooth is off"
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        peripherals[peripheral.identifier] = nil
        levels[peripheral.identifier] = nil
        emit()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == batteryService {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevel {
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let byte = characteristic.value?.first else { return }
        levels[peripheral.identifier, default: [:]][ObjectIdentifier(characteristic)] = (Int(byte), Date())
        emit()
    }
}
