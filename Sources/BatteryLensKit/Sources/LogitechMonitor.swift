import BatteryLensShared
import Foundation
import IOKit.hid

/// Logitech devices over HID++: Bluetooth devices directly, and up to six devices behind
/// each Bolt, Unifying or Lightspeed receiver. Gives exact percentages and charging state.
/// Opening the HID++ interface needs Input Monitoring.
public final class LogitechMonitor: BatterySource {
    public let kind = SourceKind.logitech
    public private(set) var status = "not started"
    /// False until Input Monitoring is allowed; `refresh()` tries again.
    private var isOpen = false
    public var onReadings: (([BatteryReading]) -> Void)?

    private var manager: IOHIDManager?
    private var links: [UInt64: LogitechLink] = [:]
    /// Keyed by link and device index.
    private var readings: [String: BatteryReading] = [:]
    private var timer: Timer?

    public init() {}

    public func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF43], // Bluetooth
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF00], // receivers, USB
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<LogitechMonitor>.fromOpaque(context!).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<LogitechMonitor>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        status = isOpen ? "running" : "can't open devices (\(hex(result))); needs Input Monitoring"
        self.manager = manager
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    public func refresh() {
        if !isOpen, let manager {
            isOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            if isOpen { status = "running" }
        }
        links.values.forEach { $0.poll() }
    }

    private func added(_ device: IOHIDDevice) {
        let id = HIDDeviceInfo.registryID(device)
        guard links[id] == nil else { return }
        let product = HIDDeviceInfo.string(device, kIOHIDProductKey) ?? "Logitech device"
        // Bolt and Unifying receivers are named "USB Receiver" / "Unifying Receiver".
        let isReceiver = product.localizedCaseInsensitiveContains("receiver")
        let link = LogitechLink(device: device, product: product, isReceiver: isReceiver,
                                keys: isReceiver ? [] : HIDDeviceInfo.keys(device))
        link.onBattery = { [weak self] logiDevice, battery in
            self?.update(linkID: id, device: logiDevice, battery: battery)
        }
        links[id] = link
        link.start()
    }

    private func removed(_ device: IOHIDDevice) {
        let id = HIDDeviceInfo.registryID(device)
        links[id]?.stop()
        links[id] = nil
        readings = readings.filter { !$0.key.hasPrefix("\(id)-") }
        onReadings?(Array(readings.values))
    }

    private func update(linkID: UInt64, device: LogitechDevice, battery: HIDPP.Battery) {
        readings["\(linkID)-\(device.deviceIndex)"] = BatteryReading(
            keys: device.keys, name: device.name, kind: device.kind, percent: battery.percent,
            isCharging: battery.isCharging, source: .logitech)
        status = "running, \(readings.count) devices"
        onReadings?(Array(readings.values))
    }
}

/// A Logitech device found through HID++.
struct LogitechDevice {
    let deviceIndex: UInt8
    var name: String
    var kind: DeviceKind = .other
    var featureIndex: [HIDPP.Feature: UInt8] = [:]
    var keys: Set<String>
}

/// One HID++ interface: a Bluetooth device itself, or a receiver with up to six paired
/// devices behind it. Requests go out one at a time; each waits for its reply, an error,
/// or a timeout (a device behind a receiver may be asleep). Adapted from M3 Tracker's
/// LogitechTransport.
final class LogitechLink {
    let device: IOHIDDevice
    let product: String
    let isReceiver: Bool
    /// The interface's own identifiers; empty for a receiver.
    let keys: Set<String>
    private(set) var devices: [UInt8: LogitechDevice] = [:]
    var onBattery: ((LogitechDevice, HIDPP.Battery) -> Void)?

    private var identifying = Set<UInt8>()
    private var noBattery = Set<UInt8>()
    private var failures: [UInt8: Int] = [:]
    /// A device that has just connected or woken often doesn't answer at first.
    private static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]

    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private struct Pending {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let function: UInt8
        let params: [UInt8]
        let reply: ([UInt8]?) -> Void
    }
    private var queue: [Pending] = []
    private var inFlight: Pending?
    private var generation = 0

    init(device: IOHIDDevice, product: String, isReceiver: Bool, keys: Set<String>) {
        self.device = device
        self.product = product
        self.isReceiver = isReceiver
        self.keys = keys
    }

    deinit {
        reportBuffer.deallocate()
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let link = Unmanaged<LogitechLink>.fromOpaque(context).takeUnretainedValue()
            link.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        slots.forEach { identify(deviceIndex: $0) }
    }

    func stop() {
        queue.removeAll()
        inFlight = nil
        generation += 1
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
    }

    private var slots: [UInt8] { isReceiver ? Array(1...6) : [HIDPP.directDeviceIndex] }

    /// Re-reads batteries, and tries again to identify anything that hasn't answered.
    func poll() {
        for slot in slots where devices[slot] == nil && !noBattery.contains(slot) {
            identify(deviceIndex: slot)
        }
        devices.values.forEach(readBattery)
    }

    // MARK: - Identification

    private func identify(deviceIndex: UInt8) {
        guard !identifying.contains(deviceIndex) else { return }
        identifying.insert(deviceIndex)
        var device = LogitechDevice(deviceIndex: deviceIndex, name: product, keys: keys)
        var remaining: [HIDPP.Feature] = [.deviceInformation, .deviceNameType, .unifiedBattery, .batteryStatus]

        func lookupNext() {
            guard let feature = remaining.first else { return checkBattery() }
            remaining.removeFirst()
            send(deviceIndex, 0, function: 0, params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)]) { params in
                // A device that doesn't answer the root feature is absent or asleep.
                guard let params else { return failed() }
                if params[0] != 0 { device.featureIndex[feature] = params[0] }
                lookupNext()
            }
        }

        func checkBattery() {
            guard device.featureIndex[.unifiedBattery] != nil || device.featureIndex[.batteryStatus] != nil else {
                identifying.remove(deviceIndex)
                noBattery.insert(deviceIndex)
                return
            }
            readUnitID()
        }

        func readUnitID() {
            guard let index = device.featureIndex[.deviceInformation] else { return readType() }
            send(deviceIndex, index, function: 0) { params in
                if let unit = params.flatMap(HIDPP.unitID) { device.keys.insert("logi:unit-\(unit)") }
                readType()
            }
        }

        func readType() {
            guard let index = device.featureIndex[.deviceNameType] else {
                device.kind = HIDDeviceInfo.kind(self.device)
                return finish()
            }
            send(deviceIndex, index, function: 2) { params in
                device.kind = params.map { HIDPP.kind(deviceType: $0[0]) } ?? HIDDeviceInfo.kind(self.device)
                readName()
            }
        }

        // A receiver's product name is the receiver's, so ask the device its own.
        func readName() {
            guard isReceiver, let nameIndex = device.featureIndex[.deviceNameType] else { return finish() }
            send(deviceIndex, nameIndex, function: 0) { params in
                guard let length = params?.first, length > 0 else { return finish() }
                var name: [UInt8] = []
                func readChunk() {
                    guard name.count < Int(length) else {
                        device.name = String(decoding: name, as: UTF8.self)
                        return finish()
                    }
                    self.send(deviceIndex, nameIndex, function: 1, params: [UInt8(name.count)]) { params in
                        guard let params else { return finish() }
                        let chunk = params.prefix(Int(length) - name.count).prefix { $0 != 0 }
                        guard !chunk.isEmpty else { return finish() }
                        name += chunk
                        readChunk()
                    }
                }
                readChunk()
            }
        }

        func finish() {
            identifying.remove(deviceIndex)
            failures[deviceIndex] = nil
            devices[deviceIndex] = device
            readBattery(device)
        }

        func failed() {
            identifying.remove(deviceIndex)
            // Empty receiver slots never answer; they're retried by poll() and when the
            // receiver reports a device connecting, not on a timer.
            guard !isReceiver else { return }
            let attempt = (failures[deviceIndex] ?? 0) + 1
            failures[deviceIndex] = attempt
            guard attempt <= Self.retryDelays.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt - 1]) { [weak self] in
                guard let self, self.devices[deviceIndex] == nil else { return }
                self.identify(deviceIndex: deviceIndex)
            }
        }

        lookupNext()
    }

    private func readBattery(_ device: LogitechDevice) {
        if let index = device.featureIndex[.unifiedBattery] {
            send(device.deviceIndex, index, function: 1) { [weak self] params in
                guard let battery = params.flatMap(HIDPP.unifiedBattery) else { return }
                self?.onBattery?(device, battery)
            }
        } else if let index = device.featureIndex[.batteryStatus] {
            send(device.deviceIndex, index, function: 0) { [weak self] params in
                guard let battery = params.flatMap(HIDPP.batteryStatus) else { return }
                self?.onBattery?(device, battery)
            }
        }
    }

    // MARK: - I/O

    /// `reply` gets the parameters, or nil on an error or no answer.
    private func send(_ deviceIndex: UInt8, _ featureIndex: UInt8, function: UInt8, params: [UInt8] = [],
                      reply: @escaping ([UInt8]?) -> Void) {
        queue.append(Pending(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function,
                             params: params, reply: reply))
        sendNextIfIdle()
    }

    private func sendNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        inFlight = request
        let report = HIDPP.request(deviceIndex: request.deviceIndex, featureIndex: request.featureIndex,
                                   function: request.function, params: request.params)
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPP.longReportID),
                                          report, report.count)
        guard result == kIOReturnSuccess else { return complete(with: nil) }

        generation += 1
        let sent = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == sent, self.inFlight != nil else { return }
            self.complete(with: nil)
        }
    }

    private func complete(with params: [UInt8]?) {
        guard let request = inFlight else { return }
        inFlight = nil
        request.reply(params)
        sendNextIfIdle()
    }

    private func received(_ report: [UInt8]) {
        switch HIDPP.parse(report) {
        case let .response(deviceIndex, featureIndex, function, params)?:
            guard let request = inFlight, request.deviceIndex == deviceIndex,
                  request.featureIndex == featureIndex, request.function == function else { return }
            complete(with: params)
        case let .error(deviceIndex, featureIndex, function)?:
            guard let request = inFlight, request.deviceIndex == deviceIndex,
                  request.featureIndex == featureIndex, request.function == function else { return }
            complete(with: nil)
        case let .event(deviceIndex, featureIndex, _, params)?:
            // Devices announce battery changes (feature 0x1004) themselves.
            guard let device = devices[deviceIndex], featureIndex == device.featureIndex[.unifiedBattery],
                  let battery = HIDPP.unifiedBattery(params) else { return }
            onBattery?(device, battery)
        case let .receiverConnection(deviceIndex)?:
            // A device behind a receiver woke up or was paired: (re)identify it.
            guard isReceiver, (1...6).contains(deviceIndex) else { return }
            noBattery.remove(deviceIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.identify(deviceIndex: deviceIndex)
            }
        case nil:
            break
        }
    }
}
