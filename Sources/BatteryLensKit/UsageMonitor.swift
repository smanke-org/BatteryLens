import BatteryLensShared
import Foundation
import IOKit.hid

/// Counts the minutes a tracked device is in use: any key press, click or movement it
/// sends marks the current minute as active. Only when input arrives is recorded,
/// never which key or where; it needs Input Monitoring, like the HID battery source.
public final class UsageMonitor {
    /// Device keys ("bt:…", "uuid:…") to count; input from anything else is ignored.
    public var tracked: Set<String> = []
    /// Called once per device per active minute, on the main thread.
    public var onActiveMinute: ((String, Date) -> Void)?
    public private(set) var status = "not started"

    private var manager: IOHIDManager?
    private var isOpen = false
    private var keysByDevice: [UInt64: Set<String>] = [:]
    private var lastMinute: [String: Int] = [:]
    /// Devices input has come from since launch, for Diagnostics.
    public private(set) var heard = Set<String>()

    public init() {}

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDTransportKey: "Bluetooth"],
            [kIOHIDTransportKey: "Bluetooth Low Energy"],
        ] as CFArray)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad],
            [kIOHIDElementUsagePageKey: kHIDPage_Button],
            [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop, kIOHIDElementUsageKey: kHIDUsage_GD_X],
            [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop, kIOHIDElementUsageKey: kHIDUsage_GD_Wheel],
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<UsageMonitor>.fromOpaque(context!).takeUnretainedValue().received(value, from: device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<UsageMonitor>.fromOpaque(context!).takeUnretainedValue().keysByDevice[HIDDeviceInfo.registryID(device)] = nil
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        open()
    }

    /// Tries again after Input Monitoring is allowed.
    public func refresh() {
        if !isOpen { open() }
    }

    private func open() {
        guard let manager else { return }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        status = isOpen ? "counting" : "can't open devices (\(hex(result))); needs Input Monitoring"
    }

    private func received(_ value: IOHIDValue, from device: IOHIDDevice) {
        let element = IOHIDValueGetElement(value)
        // Key releases and zero movement aren't use.
        if IOHIDValueGetIntegerValue(value) == 0 { return }
        if IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad), IOHIDElementGetUsage(element) < 4 { return }

        let id = HIDDeviceInfo.registryID(device)
        let keys = keysByDevice[id] ?? {
            let keys = HIDDeviceInfo.keys(device)
            keysByDevice[id] = keys
            // Once per device per launch, for Diagnostics: which devices it hears from.
            let name = HIDDeviceInfo.string(device, kIOHIDProductKey) ?? "unnamed device"
            SharedContainer.logger.info("usage: hearing \(name, privacy: .public) [\(keys.sorted().joined(separator: ", "), privacy: .public)]")
            heard.insert(name)
            return keys
        }()
        guard !tracked.isEmpty, let key = keys.intersection(tracked).sorted().first else { return }
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard lastMinute[key] != minute else { return }
        lastMinute[key] = minute
        onActiveMinute?(key, now)
    }
}
