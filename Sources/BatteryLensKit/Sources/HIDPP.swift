import BatteryLensShared
import Foundation

/// Logitech's HID++ 2.0 protocol, just enough to identify a device and read its battery.
/// Pure encoding and decoding; `LogitechLink` does the I/O. Same encoding as M3 Tracker's
/// HIDPP.swift, extended to every device type.
///
/// A long report is 20 bytes: report ID 0x11, device index, feature index,
/// function (high nibble) | software ID (low nibble), then 16 parameter bytes.
/// Bluetooth devices answer on device index 0xFF; devices behind a Bolt or Unifying
/// receiver answer on their pairing slot, 1–6.
enum HIDPP {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    /// Tags our requests. Logi Options+ and M3 Tracker use their own, so replies to their
    /// requests (which every opener of the device also receives) are ignored.
    static let softwareID: UInt8 = 0x0C
    static let directDeviceIndex: UInt8 = 0xFF

    enum Feature: UInt16, CaseIterable {
        case root = 0x0000
        case deviceInformation = 0x0003
        case deviceNameType = 0x0005
        case batteryStatus = 0x1000
        case unifiedBattery = 0x1004
    }

    /// From feature 0x0005 `getDeviceType`.
    static func kind(deviceType: UInt8) -> DeviceKind {
        switch deviceType {
        case 0, 2: .keyboard // keyboard, numpad
        case 3, 5: .mouse // mouse, trackball
        case 4: .trackpad
        case 8: .headphones // headset
        case 11, 12: .controller // joystick, gamepad
        default: .other
        }
    }

    static func request(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8] = []) -> [UInt8] {
        var report: [UInt8] = [longReportID, deviceIndex, featureIndex, (function << 4) | softwareID]
        report += params.prefix(longReportLength - report.count)
        report += Array(repeating: 0, count: longReportLength - report.count)
        return report
    }

    enum Message: Equatable {
        /// A reply to one of our requests.
        case response(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8])
        /// Something the device sent on its own, such as a battery change.
        case event(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8])
        /// Our request failed: an unknown feature, or a device that's asleep.
        case error(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8)
        /// A receiver reporting that a paired device connected or disconnected.
        case receiverConnection(deviceIndex: UInt8)
    }

    /// Nil for anything that isn't HID++, or that answers another app's request.
    static func parse(_ report: [UInt8]) -> Message? {
        guard report.count >= 7, report[0] == shortReportID || report[0] == longReportID else { return nil }
        let deviceIndex = report[1]
        switch report[2] {
        case 0xFF, 0x8F:
            // HID++ 2.0 and 1.0 error replies: the failed request's feature index and
            // function|software ID follow.
            guard report[4] & 0x0F == softwareID else { return nil }
            return .error(deviceIndex: deviceIndex, featureIndex: report[3], function: report[4] >> 4)
        case 0x41 where report[0] == shortReportID:
            return .receiverConnection(deviceIndex: deviceIndex)
        default:
            var params = Array(report[4...])
            params += Array(repeating: 0, count: max(0, 16 - params.count))
            let software = report[3] & 0x0F
            let function = report[3] >> 4
            if software == softwareID {
                return .response(deviceIndex: deviceIndex, featureIndex: report[2], function: function, params: params)
            }
            if software == 0 {
                return .event(deviceIndex: deviceIndex, featureIndex: report[2], function: function, params: params)
            }
            return nil
        }
    }

    struct Battery: Equatable {
        var percent: Int
        /// Plugged in, whether still charging or full.
        var isCharging: Bool
    }

    /// Feature 0x1004 `getStatus` (function 1), and its battery events. params[0] is the
    /// charge in percent (0 on devices that only report coarse levels); params[1] the level
    /// as flags (1 critical, 2 low, 4 good, 8 full); params[2] is 0 discharging, 1–2
    /// charging, 3 charged, 4 error.
    static func unifiedBattery(_ params: [UInt8]) -> Battery? {
        guard params.count >= 3, params[0] <= 100 else { return nil }
        let charging = (1...3).contains(params[2])
        if params[0] > 0 { return Battery(percent: Int(params[0]), isCharging: charging) }
        // Coarse levels only: the middle of each band.
        let flags = params[1]
        let percent = flags & 0x08 != 0 ? 100 : flags & 0x04 != 0 ? 60 : flags & 0x02 != 0 ? 20 : flags & 0x01 != 0 ? 5 : nil
        return percent.map { Battery(percent: $0, isCharging: charging) }
    }

    /// Feature 0x1000 `getBatteryLevelStatus` (function 0), for older devices.
    /// params[2] is 0 discharging, 1 recharging, 2 almost full, 3 full, 4 slow recharge.
    static func batteryStatus(_ params: [UInt8]) -> Battery? {
        guard params.count >= 3, params[0] <= 100, params[0] > 0 else { return nil }
        return Battery(percent: Int(params[0]), isCharging: (1...4).contains(params[2]))
    }

    /// Feature 0x0003 `getDeviceInfo` (function 0): the 4-byte unit ID.
    static func unitID(_ params: [UInt8]) -> String? {
        guard params.count >= 5 else { return nil }
        let id = params[1...4].map { String(format: "%02x", $0) }.joined()
        return id == "00000000" ? nil : id
    }
}
