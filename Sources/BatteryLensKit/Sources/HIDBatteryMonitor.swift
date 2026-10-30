import BatteryLensShared
import Foundation
import IOKit.hid

/// Battery Strength (Generic Device Controls 0x20) that Bluetooth keyboards and mice
/// declare in their HID report descriptors and send in an input report. macOS doesn't
/// show it, so it's read here: the value macOS cached from the last report, then every
/// new report as it arrives. Opening keyboards needs Input Monitoring.
///
/// A device that declares the field but never sends it (the Matias keyboard) simply
/// produces no reading; a value whose timestamp is 0 was never sent and isn't 0%.
public final class HIDBatteryMonitor: BatterySource {
    public let kind = SourceKind.hid
    public private(set) var status = "not started"
    /// False until Input Monitoring is allowed; `refresh()` tries again.
    private var isOpen = false
    public var onReadings: (([BatteryReading]) -> Void)?

    private var manager: IOHIDManager?
    private var readings: [UInt64: BatteryReading] = [:]
    private static let matching = [kIOHIDElementUsagePageKey: 0x06, kIOHIDElementUsageKey: 0x20] as CFDictionary

    public init() {}

    public func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDTransportKey: "Bluetooth"],
            [kIOHIDTransportKey: "Bluetooth Low Energy"],
        ] as CFArray)
        IOHIDManagerSetInputValueMatching(manager, Self.matching)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<HIDBatteryMonitor>.fromOpaque(context!).takeUnretainedValue().readCached(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let monitor = Unmanaged<HIDBatteryMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.readings[HIDDeviceInfo.registryID(device)] = nil
            monitor.emit()
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<HIDBatteryMonitor>.fromOpaque(context!).takeUnretainedValue().received(value, from: device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        status = isOpen ? "listening" : "can't open devices (\(hex(result))); needs Input Monitoring"
        self.manager = manager
    }

    public func refresh() {
        if !isOpen, let manager {
            isOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            if isOpen { status = "listening" }
        }
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        devices.forEach(readCached)
    }

    /// The value macOS kept from the device's last battery report, without asking the device.
    private func readCached(_ device: IOHIDDevice) {
        let elements = IOHIDDeviceCopyMatchingElements(device, Self.matching, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        for element in elements {
            let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
            var value = Unmanaged.passUnretained(placeholder)
            // kIOHIDDeviceGetValueWithoutUpdate: an anonymous enum, so not imported by name.
            if IOHIDDeviceGetValueWithOptions(device, element, &value, 0x0004_0000) == kIOReturnSuccess {
                received(value.takeUnretainedValue(), from: device)
            }
            withExtendedLifetime(placeholder) {}
        }
    }

    private func received(_ value: IOHIDValue, from device: IOHIDDevice) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 0x06, IOHIDElementGetUsage(element) == 0x20,
              IOHIDValueGetTimeStamp(value) > 0 else { return }
        let min = IOHIDElementGetLogicalMin(element), max = IOHIDElementGetLogicalMax(element)
        guard max > min else { return }
        let percent = (IOHIDValueGetIntegerValue(value) - min) * 100 / (max - min)
        readings[HIDDeviceInfo.registryID(device)] = BatteryReading(
            keys: HIDDeviceInfo.keys(device), name: HIDDeviceInfo.string(device, kIOHIDProductKey) ?? "Bluetooth device",
            kind: HIDDeviceInfo.kind(device), percent: Swift.max(0, Swift.min(100, percent)), source: .hid)
        emit()
    }

    private func emit() {
        onReadings?(Array(readings.values))
    }
}
