import BatteryLensShared
import Foundation
import IOKit
import IOKit.hid

/// One way of reading batteries. A source reports its complete current set of readings
/// each time anything changes; the hub merges all sources. Everything runs on the main
/// run loop.
public protocol BatterySource: AnyObject {
    var kind: SourceKind { get }
    /// One line for diagnostics: running, waiting for a permission, and so on.
    var status: String { get }
    var onReadings: (([BatteryReading]) -> Void)? { get set }
    func start()
    /// Re-reads now; sources also refresh on their own.
    func refresh()
}

/// "AA-BB-CC-11-22-33" and "aa:bb:cc:11:22:33" are the same address.
public func normalizedAddress(_ address: String) -> String? {
    let hex = address.lowercased().filter(\.isHexDigit)
    guard hex.count == 12 else { return nil }
    return stride(from: 0, to: 12, by: 2).map { i in
        String(hex[hex.index(hex.startIndex, offsetBy: i)...].prefix(2))
    }.joined(separator: ":")
}

/// IOKit property lookups shared by the HID-based sources.
enum HIDDeviceInfo {
    static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        property(device, key) as? String
    }

    static func number(_ device: IOHIDDevice, _ key: String) -> Int {
        property(device, key) as? Int ?? 0
    }

    /// Some properties, such as PhysicalDeviceUniqueID, live on the device's children
    /// rather than on the device itself.
    static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        if let value = IOHIDDeviceGetProperty(device, key as CFString) { return value }
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                               IOOptionBits(kIORegistryIterateRecursively))
    }

    static func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    /// The identifiers other sources know this device by: CoreBluetooth and the power
    /// list use the same UUID for Bluetooth LE devices; classic Bluetooth devices carry
    /// their address as the serial number.
    static func keys(_ device: IOHIDDevice) -> Set<String> {
        var keys = Set<String>()
        if let uuid = string(device, "PhysicalDeviceUniqueID") { keys.insert("uuid:\(uuid)") }
        if string(device, kIOHIDTransportKey) == "Bluetooth",
           let address = string(device, kIOHIDSerialNumberKey).flatMap(normalizedAddress) {
            keys.insert("bt:\(address)")
        }
        return keys
    }

    static func kind(_ device: IOHIDDevice) -> DeviceKind {
        guard number(device, kIOHIDPrimaryUsagePageKey) == kHIDPage_GenericDesktop else { return .other }
        switch number(device, kIOHIDPrimaryUsageKey) {
        case kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad: return .keyboard
        case kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer: return .mouse
        case kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick: return .controller
        default: return .other
        }
    }
}

func hex(_ value: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: value)) }
