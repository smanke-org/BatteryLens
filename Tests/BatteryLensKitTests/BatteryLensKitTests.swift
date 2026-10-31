@testable import BatteryLensKit
import BatteryLensShared
import XCTest

final class PowerSourceTests: XCTestCase {
    func testBluetoothMouse() throws {
        let reading = try XCTUnwrap(PowerSourceMonitor.reading(from: [
            "Type": "Accessory Source", "Name": "MX Master 4 M", "Accessory Category": "Mouse",
            "Accessory Identifier": "8DC4DE04-ACFB-9BAE-2369-A3DB9E0EDD24",
            "Current Capacity": 85, "Max Capacity": 100, "Is Charging": false,
        ]))
        XCTAssertEqual(reading.kind, .mouse)
        XCTAssertEqual(reading.percent, 85)
        XCTAssertEqual(reading.keys, ["uuid:8DC4DE04-ACFB-9BAE-2369-A3DB9E0EDD24"])
        XCTAssertNil(reading.part)
    }

    func testEarbudsCase() throws {
        let reading = try XCTUnwrap(PowerSourceMonitor.reading(from: [
            "Type": "Accessory Source", "Name": "Earbuds Case", "Accessory Category": "Audio Battery Case",
            "Accessory Identifier": "A", "Group Identifier": "G", "Current Capacity": 88, "Max Capacity": 100,
        ]))
        XCTAssertEqual(reading.part, .chargingCase)
        XCTAssertEqual(reading.kind, .earbuds)
        XCTAssertTrue(reading.keys.contains("group:G"))
    }

    /// The shape macOS 27 uses for AirPods buds: one "Combined" source with the buds inside.
    func testCombinedEarbuds() {
        let readings = PowerSourceMonitor.readings(from: [
            "Type": "Accessory Source", "Name": "Earbuds", "Accessory Category": "Headset", "Part Identifier": "Combined",
            "Accessory Identifier": "C", "Group Identifier": "G", "Current Capacity": 80, "Max Capacity": 100,
            "Combined Parts": [
                ["Accessory Category": "Headset", "Accessory Identifier": "C", "Group Identifier": "G",
                 "Part Identifier": "Left", "Current Capacity": 78, "Max Capacity": 100],
                ["Accessory Category": "Headset", "Accessory Identifier": "C", "Group Identifier": "G",
                 "Part Identifier": "Right", "Current Capacity": 80, "Max Capacity": 100, "Is Charging": true],
            ],
        ])
        XCTAssertEqual(readings.map(\.part), [.left, .right])
        XCTAssertEqual(readings.map(\.percent), [78, 80])
        XCTAssertEqual(readings.map(\.name), ["Earbuds", "Earbuds"])
        XCTAssertEqual(readings.map(\.kind), [.earbuds, .earbuds])
    }

    func testInternalBattery() throws {
        let reading = try XCTUnwrap(PowerSourceMonitor.reading(from: [
            "Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 80, "Max Capacity": 100,
            "Is Charging": true,
        ], macName: "Test Mac"))
        XCTAssertEqual(reading.kind, .mac)
        XCTAssertEqual(reading.name, "Test Mac")
        XCTAssertTrue(reading.isCharging)
    }
}

final class ProfilerTests: XCTestCase {
    func testEarbudsAndSilentKeyboard() {
        let json = """
        {"SPBluetoothDataType":[{
          "device_connected":[{"Keyboard":{"device_address":"AA:BB:CC:11:22:33","device_minorType":"Keyboard"}},
                              {"Speaker":{"device_address":"11:22:33:44:55:66","device_minorType":"Speaker"}}],
          "device_not_connected":[{"Earbuds":{"device_address":"34:0E:22:75:7E:A5","device_minorType":"Headphones",
              "device_batteryLevelLeft":"80%","device_batteryLevelRight":"79%","device_batteryLevelCase":"88%"}}]
        }]}
        """
        let readings = BluetoothProfilerMonitor.readings(from: Data(json.utf8))
        let keyboard = readings.filter { $0.name == "Keyboard" }
        XCTAssertEqual(keyboard.count, 1)
        XCTAssertNil(keyboard.first?.percent)
        XCTAssertEqual(keyboard.first?.keys, ["bt:aa:bb:cc:11:22:33"])
        XCTAssertTrue(readings.allSatisfy { $0.name != "Speaker" }, "devices with no battery aren't listed")
        let earbuds = readings.filter { $0.name == "Earbuds" }
        XCTAssertEqual(Set(earbuds.compactMap(\.part)), [.left, .right, .chargingCase])
        XCTAssertTrue(earbuds.allSatisfy { !$0.isConnected })
    }

    func testAddressNormalization() {
        XCTAssertEqual(normalizedAddress("AA-BB-CC-11-22-33"), "aa:bb:cc:11:22:33")
        XCTAssertNil(normalizedAddress("A72CB756"))
    }
}

final class MergerTests: XCTestCase {
    private func reading(_ keys: Set<String>, _ name: String, _ percent: Int?, source: SourceKind, kind: DeviceKind = .other,
                         part: BatteryPart? = nil, connected: Bool = true) -> BatteryReading {
        BatteryReading(keys: keys, name: name, kind: kind, part: part, percent: percent, isConnected: connected, source: source)
    }

    func testOneMouseAcrossSources() {
        let devices = DeviceMerger.merge([
            reading(["uuid:A"], "MX Master 4 M", 84, source: .powerList, kind: .mouse),
            reading(["uuid:A", "logi:unit-1"], "MX Master 4 for Mac", 85, source: .logitech, kind: .mouse),
            reading(["uuid:A"], "MX Master 4 M", 84, source: .ble),
            reading(["bt:dc:03"], "MX Master 4 M", nil, source: .profiler, kind: .mouse),
        ])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "MX Master 4 M", "the Bluetooth name wins over the HID++ product name")
        XCTAssertEqual(devices[0].levels.map(\.percent), [85], "HID++ is the most trusted source")
        XCTAssertEqual(devices[0].levels.first?.source, .logitech)
    }

    func testSameNameDifferentDevicesStayApart() {
        let devices = DeviceMerger.merge([
            reading(["bt:aa"], "MX Master 3S M", 50, source: .profiler, kind: .mouse),
            reading(["bt:bb"], "MX Master 3S M", 70, source: .profiler, kind: .mouse),
        ])
        XCTAssertEqual(devices.count, 2)
    }

    func testEarbudsFromPowerListAndProfiler() {
        let devices = DeviceMerger.merge([
            reading(["uuid:R", "group:G"], "Earbuds", 80, source: .powerList, kind: .earbuds, part: .right),
            reading(["uuid:C", "group:G"], "Earbuds Case", 88, source: .powerList, kind: .earbuds, part: .chargingCase),
            reading(["bt:34"], "Earbuds", 79, source: .profiler, kind: .earbuds, part: .left, connected: false),
            reading(["bt:34"], "Earbuds", 70, source: .profiler, kind: .earbuds, part: .right, connected: false),
        ])
        XCTAssertEqual(devices.count, 1)
        let device = devices[0]
        XCTAssertEqual(device.name, "Earbuds")
        XCTAssertEqual(device.levels.map(\.part), [.left, .right, .chargingCase])
        XCTAssertEqual(device.levels.first { $0.part == .right }?.percent, 80, "the live power list beats System Information")
        XCTAssertTrue(device.isConnected)
        XCTAssertEqual(device.lowest, 79, "the case doesn't count toward the lowest level")
    }

    /// System Information adds the address only every few minutes; the ID mustn't change when it does.
    func testIDSurvivesASourceJoining() {
        var known: [String: String] = [:]
        let first = DeviceMerger.merge([reading(["uuid:A"], "Mouse", 85, source: .powerList, kind: .mouse)], knownIDs: &known)
        let later = DeviceMerger.merge([
            reading(["uuid:A"], "Mouse", 85, source: .powerList, kind: .mouse),
            reading(["bt:dc:03"], "Mouse", nil, source: .profiler, kind: .mouse),
        ], knownIDs: &known)
        let alone = DeviceMerger.merge([reading(["bt:dc:03"], "Mouse", nil, source: .profiler, kind: .mouse)], knownIDs: &known)
        XCTAssertEqual(first.map(\.id), ["uuid:A"])
        XCTAssertEqual(later.map(\.id), ["uuid:A"])
        XCTAssertEqual(alone.map(\.id), ["uuid:A"])
        XCTAssertNil(SnapshotDiff.reloadReason(from: first, to: later))
    }

    func testMacSortsFirst() {
        let devices = DeviceMerger.merge([
            reading(["uuid:A"], "Alpha Mouse", 50, source: .powerList, kind: .mouse),
            reading(["mac:internal"], "Zed's Mac", 80, source: .powerList, kind: .mac),
        ])
        XCTAssertEqual(devices.first?.kind, .mac)
    }
}

final class DeviceStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func mouse(_ percent: Int?, connected: Bool = true, keys: Set<String> = ["uuid:A"], date: Date) -> DeviceBattery {
        DeviceBattery(id: "uuid:A", name: "Mouse", kind: .mouse, keys: keys,
                      levels: percent.map { [.init(part: nil, percent: $0, isCharging: false, source: .powerList, date: date)] } ?? [],
                      isConnected: connected, updated: date)
    }

    func testDisconnectedDeviceKeepsLastLevel() {
        let store = DeviceStore(fileURL: nil)
        _ = store.update(with: [mouse(85, date: start)], now: start)
        let later = start.addingTimeInterval(3600)
        let devices = store.update(with: [], now: later)
        XCTAssertEqual(devices.count, 1)
        XCTAssertFalse(devices[0].isConnected)
        XCTAssertEqual(devices[0].levels.first?.percent, 85)
        XCTAssertEqual(devices[0].updated, start, "the age of the last-known level")
    }

    func testConnectedWithoutLevelKeepsLastKnown() {
        let store = DeviceStore(fileURL: nil)
        _ = store.update(with: [mouse(85, date: start)], now: start)
        _ = store.update(with: [mouse(nil, date: start)], now: start.addingTimeInterval(60))
        XCTAssertEqual(store.remembered["uuid:A"]?.levels.first?.percent, 85)
    }

    func testSettingsAndVisibility() {
        let store = DeviceStore(fileURL: nil)
        store.setSettings(DeviceSettings(customName: "Desk Mouse", lowThreshold: 30), for: "uuid:A")
        let devices = store.update(with: [mouse(85, date: start)], now: start)
        XCTAssertEqual(devices.first?.name, "Desk Mouse")
        XCTAssertEqual(devices.first?.threshold, 30)
        XCTAssertEqual(store.visible(devices).count, 1)
        store.setSettings(DeviceSettings(isReporting: false), for: "uuid:A")
        XCTAssertTrue(store.visible(store.update(with: [mouse(85, date: start)], now: start)).isEmpty)
    }

    func testOldDevicesAreForgotten() {
        let store = DeviceStore(fileURL: nil)
        _ = store.update(with: [mouse(85, date: start)], now: start)
        XCTAssertTrue(store.update(with: [], now: start.addingTimeInterval(DeviceStore.retention + 60)).isEmpty)
        XCTAssertNil(store.knownIDs["uuid:A"])
    }

    func testSavesAndReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryLensTests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DeviceStore(fileURL: url)
        _ = store.update(with: [mouse(85, date: start)], now: start)
        store.setSettings(DeviceSettings(isHidden: true), for: "uuid:A")
        let reloaded = DeviceStore(fileURL: url)
        XCTAssertEqual(reloaded.remembered["uuid:A"]?.levels.first?.percent, 85)
        XCTAssertTrue(reloaded.settings(for: "uuid:A").isHidden)
        XCTAssertEqual(reloaded.knownIDs["uuid:A"], "uuid:A")
    }

    /// Two entries remembered apart turn out to be one device: the second folds into the first.
    func testDuplicatesFold() {
        let store = DeviceStore(fileURL: nil)
        let other = DeviceBattery(id: "bt:dc", name: "Mouse", kind: .mouse, keys: ["bt:dc"], levels: [],
                                  isConnected: true, updated: start)
        _ = store.update(with: [mouse(85, date: start), other], now: start)
        store.setSettings(DeviceSettings(customName: "Desk Mouse"), for: "bt:dc")
        let devices = store.update(with: [mouse(85, keys: ["uuid:A", "bt:dc"], date: start)], now: start)
        XCTAssertEqual(devices.map(\.id), ["uuid:A"])
        XCTAssertEqual(devices.first?.name, "Desk Mouse", "settings move with the folded entry")
    }
}

final class AlertMonitorTests: XCTestCase {
    private func mouse(_ percent: Int, charging: Bool = false, threshold: Int = 20) -> DeviceBattery {
        DeviceBattery(id: "m", name: "Mouse", kind: .mouse, keys: [],
                      levels: [.init(part: nil, percent: percent, isCharging: charging, source: .powerList, date: Date())],
                      isConnected: true, updated: Date(), lowThreshold: threshold)
    }

    func testLowOncePerDischarge() {
        let monitor = AlertMonitor()
        XCTAssertTrue(monitor.check([mouse(25)], lowEnabled: true, fullEnabled: false).isEmpty)
        XCTAssertEqual(monitor.check([mouse(20)], lowEnabled: true, fullEnabled: false).map(\.kind), [.low])
        XCTAssertTrue(monitor.check([mouse(19)], lowEnabled: true, fullEnabled: false).isEmpty)
        XCTAssertTrue(monitor.check([mouse(22)], lowEnabled: true, fullEnabled: false).isEmpty, "a wobble doesn't re-arm")
        XCTAssertTrue(monitor.check([mouse(20)], lowEnabled: true, fullEnabled: false).isEmpty)
        _ = monitor.check([mouse(30, charging: true)], lowEnabled: true, fullEnabled: false)
        XCTAssertEqual(monitor.check([mouse(18)], lowEnabled: true, fullEnabled: false).count, 1, "charging re-arms")
    }

    func testOwnThresholdAndRelaunch() {
        let monitor = AlertMonitor()
        XCTAssertEqual(monitor.check([mouse(35, threshold: 40)], lowEnabled: true, fullEnabled: false).count, 1)
        let relaunched = AlertMonitor(fired: monitor.fired)
        XCTAssertTrue(relaunched.check([mouse(35, threshold: 40)], lowEnabled: true, fullEnabled: false).isEmpty)
    }

    func testFullOncePerCharge() {
        let monitor = AlertMonitor()
        XCTAssertEqual(monitor.check([mouse(100, charging: true)], lowEnabled: true, fullEnabled: true).map(\.kind), [.full])
        XCTAssertTrue(monitor.check([mouse(100, charging: true)], lowEnabled: true, fullEnabled: true).isEmpty)
        _ = monitor.check([mouse(90)], lowEnabled: true, fullEnabled: true)
        XCTAssertEqual(monitor.check([mouse(100, charging: true)], lowEnabled: true, fullEnabled: true).count, 1)
    }

    func testMacCasesAndDisabledAlertsLeftOut() {
        let monitor = AlertMonitor()
        let mac = DeviceBattery(id: "mac", name: "Mac", kind: .mac, keys: [],
                                levels: [.init(part: nil, percent: 5, isCharging: false, source: .powerList, date: Date())],
                                isConnected: true, updated: Date())
        let earbuds = DeviceBattery(id: "e", name: "Earbuds", kind: .earbuds, keys: [],
                                    levels: [.init(part: .chargingCase, percent: 5, isCharging: false, source: .powerList, date: Date())],
                                    isConnected: true, updated: Date())
        XCTAssertTrue(monitor.check([mac, earbuds], lowEnabled: true, fullEnabled: true).isEmpty)
        XCTAssertTrue(monitor.check([mouse(10)], lowEnabled: false, fullEnabled: false).isEmpty)
        XCTAssertTrue(monitor.check([mouse(10)], lowEnabled: true, fullEnabled: false).isEmpty,
                      "turning alerts on later doesn't replay one already due")
    }
}

final class EstimatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func log(_ mac: String, minutes: [(hoursAfterStart: Int, minutes: Int)], charges: [ChargeMark] = []) -> UsageLog {
        var log = UsageLog(macID: mac, macName: mac, charges: charges)
        for entry in minutes {
            log.minutes["bt:kb", default: [:]][String(UsageLog.hour(start) + entry.hoursAfterStart)] = entry.minutes
        }
        return log
    }

    func testNoEstimateUntilMarked() {
        XCTAssertNil(Estimator.estimate(for: "bt:kb", logs: [log("a", minutes: [(1, 60)])], now: start))
    }

    func testStartingGuessAndUseOnEveryMac() {
        let mark = ChargeMark(device: "bt:kb", date: start, ranOut: false)
        // 10 h here and 15 h on another Mac: a quarter of the 100-hour guess.
        let logs = [log("a", minutes: (1...10).map { ($0, 60) }, charges: [mark]),
                    log("b", minutes: (11...25).map { ($0, 60) })]
        let estimate = Estimator.estimate(for: "bt:kb", logs: logs, now: start.addingTimeInterval(30 * 3600))
        XCTAssertEqual(estimate?.percent, 75)
        XCTAssertEqual(estimate?.learnedFrom, 0)
    }

    func testUseBeforeTheChargeDoesNotCount() {
        let mark = ChargeMark(device: "bt:kb", date: start.addingTimeInterval(5 * 3600), ranOut: false)
        let logs = [log("a", minutes: [(2, 60), (3, 60), (5, 30)], charges: [mark])]
        XCTAssertEqual(Estimator.estimate(for: "bt:kb", logs: logs, now: start.addingTimeInterval(6 * 3600))?.percent, 100)
    }

    func testLearnsFromRunningOut() {
        let first = ChargeMark(device: "bt:kb", date: start, ranOut: false)
        let ranOut = ChargeMark(device: "bt:kb", date: start.addingTimeInterval(41 * 3600), ranOut: true)
        // 40 h of use until it ran out, then 10 h since: a quarter of a charge gone.
        let logs = [log("a", minutes: (1...40).map { ($0, 60) } + (42...51).map { ($0, 60) }, charges: [first, ranOut])]
        let estimate = Estimator.estimate(for: "bt:kb", logs: logs, now: start.addingTimeInterval(52 * 3600))
        XCTAssertEqual(estimate?.hoursPerCharge, 40)
        XCTAssertEqual(estimate?.learnedFrom, 1)
        XCTAssertEqual(estimate?.percent, 75)
    }

    func testEarlyChargeTeachesNothingAndLevelNeverGoesNegative() {
        let first = ChargeMark(device: "bt:kb", date: start, ranOut: false)
        let early = ChargeMark(device: "bt:kb", date: start.addingTimeInterval(3 * 3600), ranOut: false)
        let logs = [log("a", minutes: [(1, 60), (2, 60)] + (4...200).map { ($0, 60) }, charges: [first, early])]
        let estimate = Estimator.estimate(for: "bt:kb", logs: logs, now: start.addingTimeInterval(201 * 3600))
        XCTAssertEqual(estimate?.learnedFrom, 0)
        XCTAssertEqual(estimate?.percent, 0)
    }

    /// The hour of the charge counts only the minutes after the mark.
    func testChargeHourSplits() {
        let markDate = start.addingTimeInterval(20 * 60)
        let mark = ChargeMark(device: "bt:kb", date: markDate, ranOut: false, mac: "a", minutesBefore: 12)
        let here = log("a", minutes: [(0, 30)], charges: [mark])   // 18 min after the mark
        let other = log("b", minutes: [(0, 30)])                   // 2/3 of the hour after: 20 min
        let now = start.addingTimeInterval(50 * 60)
        XCTAssertEqual(Estimator.estimate(for: "bt:kb", logs: [here, other], now: now)?.activeMinutes, 38)
    }

    func testMinutesCapAndPrune() {
        var log = UsageLog(macID: "a", macName: "a")
        for _ in 0..<70 { log.addMinute("bt:kb", at: start) }
        XCTAssertEqual(log.minutes["bt:kb"]?[String(UsageLog.hour(start))], 60)
        log.prune(before: start.addingTimeInterval(7200))
        XCTAssertNil(log.minutes["bt:kb"])
    }

    /// A disconnected device known only by its estimate shows the live estimate, not an old one.
    func testStoreKeepsFreshEstimateWhenDisconnected() {
        let store = DeviceStore(fileURL: nil)
        func keyboard(_ percent: Int) -> DeviceBattery {
            DeviceBattery(id: "bt:kb", name: "Keyboard", kind: .keyboard, keys: ["bt:kb"],
                          levels: [.init(part: nil, percent: percent, isCharging: false, source: .estimate, date: start)],
                          isConnected: false, updated: start)
        }
        _ = store.update(with: [keyboard(80)], now: start)
        XCTAssertEqual(store.update(with: [keyboard(100)], now: start).first?.levels.first?.percent, 100)
    }
}

final class ChargeHistoryTests: XCTestCase {
    func testRecordsOnlyChanges() {
        let history = ChargeHistory(fileURL: nil)
        func device(_ percent: Int, charging: Bool = false) -> DeviceBattery {
            DeviceBattery(id: "m", name: "Mouse", kind: .mouse, keys: [],
                          levels: [.init(part: nil, percent: percent, isCharging: charging, source: .powerList, date: Date())],
                          isConnected: true, updated: Date())
        }
        history.record([device(85)])
        history.record([device(85)])
        history.record([device(84)])
        history.record([device(84, charging: true)])
        XCTAssertEqual(history.samples(for: "m").map(\.percent), [85, 84, 84])
    }
}

final class HIDPPTests: XCTestCase {
    func testUnifiedBatteryResponse() {
        let report: [UInt8] = [0x11, 0xFF, 0x06, 0x1D, 85, 0x08, 0, 0] + Array(repeating: 0, count: 12)
        guard case let .response(_, featureIndex, function, softwareID, params)? = HIDPP.parse(report) else { return XCTFail() }
        XCTAssertEqual(featureIndex, 0x06)
        XCTAssertEqual(function, 1)
        XCTAssertEqual(softwareID, 0x0D)
        XCTAssertEqual(HIDPP.unifiedBattery(params), HIDPP.Battery(percent: 85, isCharging: false))
    }

    /// Each request's tag comes back with its reply, so a late reply can be told apart.
    func testSoftwareIDRoundTrips() {
        for id in HIDPP.softwareIDs {
            var reply = HIDPP.request(deviceIndex: 0xFF, featureIndex: 0, function: 0, softwareID: id, params: [0x10, 0x04])
            reply[4] = 0x06
            guard case let .response(_, _, _, softwareID, _)? = HIDPP.parse(reply) else { return XCTFail() }
            XCTAssertEqual(softwareID, id)
        }
        let error: [UInt8] = [0x11, 0xFF, 0xFF, 0x00, 0x0E, 0x05] + Array(repeating: 0, count: 14)
        XCTAssertEqual(HIDPP.parse(error), .error(deviceIndex: 0xFF, featureIndex: 0, function: 0, softwareID: 0x0E))
    }

    func testCoarseLevelsAndCharging() {
        XCTAssertEqual(HIDPP.unifiedBattery([0, 0x02, 1]), HIDPP.Battery(percent: 20, isCharging: true))
        XCTAssertNil(HIDPP.unifiedBattery([0, 0, 0]))
    }

    func testOtherAppsRepliesIgnored() {
        let report: [UInt8] = [0x11, 0xFF, 0x06, 0x1B, 85, 0x08, 0] + Array(repeating: 0, count: 13)
        XCTAssertNil(HIDPP.parse(report))
    }

    func testDeviceTypes() {
        XCTAssertEqual(HIDPP.kind(deviceType: 0), .keyboard)
        XCTAssertEqual(HIDPP.kind(deviceType: 3), .mouse)
        XCTAssertEqual(HIDPP.kind(deviceType: 8), .headphones)
    }
}

final class SnapshotDiffTests: XCTestCase {
    private func device(_ percent: Int, connected: Bool = true, charging: Bool = false) -> DeviceBattery {
        DeviceBattery(id: "bt:aa", name: "Mouse", kind: .mouse, keys: [],
                      levels: [.init(part: nil, percent: percent, isCharging: charging, source: .powerList, date: Date())],
                      isConnected: connected, updated: Date())
    }

    func testSmallChangesDontReload() {
        XCTAssertNil(SnapshotDiff.reloadReason(from: [device(80)], to: [device(77)]))
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: [device(80)], to: [device(75)]))
    }

    func testVisibleChangesReload() {
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: nil, to: []))
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: [device(80)], to: [device(80, connected: false)]))
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: [device(80)], to: [device(80, charging: true)]))
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: [device(22)], to: [device(20)]), "crossing the low threshold")
        XCTAssertNotNil(SnapshotDiff.reloadReason(from: [], to: [device(50)]))
    }

    func testSnapshotRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Snapshot.self, from: encoder.encode(Snapshot.sample))
        XCTAssertEqual(decoded.devices.map(\.id), Snapshot.sample.devices.map(\.id))
    }
}

final class ForecasterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ percent: Int, hours: Double, charging: Bool = false) -> ChargeHistory.Sample {
        .init(device: "bt:aa", part: nil, percent: percent, isCharging: charging, date: start.addingTimeInterval(hours * 3600))
    }

    func testCurrentDischarge() throws {
        // 100% → 90% over 10 hours: 1% an hour, so 90 hours left.
        let samples = (0...10).map { sample(100 - $0, hours: Double($0)) }
        let forecast = try XCTUnwrap(Forecaster.forecast(samples, percent: 90, isCharging: false,
                                                         now: start.addingTimeInterval(10 * 3600)))
        XCTAssertEqual(forecast.kind, .empty)
        XCTAssertEqual(forecast.date.timeIntervalSince(start) / 3600, 100, accuracy: 0.01)
    }

    func testTooLittleHistoryGivesNothing() {
        let samples = [sample(100, hours: 0), sample(98, hours: 3)]
        XCTAssertNil(Forecaster.forecast(samples, percent: 98, isCharging: false, now: start.addingTimeInterval(3 * 3600)))
    }

    func testFallsBackToPastDischarges() throws {
        // A past run: 100% → 80% over 20 hours, ended by a charge at hour 20.
        var samples = (0...20).map { sample(100 - $0, hours: Double($0)) }
        samples += [sample(85, hours: 20, charging: true), sample(100, hours: 22, charging: true)]
        // Just unplugged: 100% → 99%, too little to measure on its own.
        samples += [sample(100, hours: 23), sample(99, hours: 24)]
        let forecast = try XCTUnwrap(Forecaster.forecast(samples, percent: 99, isCharging: false,
                                                         now: start.addingTimeInterval(24 * 3600)))
        XCTAssertEqual(forecast.date.timeIntervalSince(start) / 3600, 24 + 99, accuracy: 0.01)
    }

    func testChargedWhileOffStartsANewRun() {
        let samples = [sample(40, hours: 0), sample(30, hours: 10), sample(100, hours: 30), sample(99, hours: 31)]
        let runs = Forecaster.runs(samples)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].samples.first?.percent, 100)
    }

    func testCharging() throws {
        let samples = [sample(50, hours: 0, charging: true), sample(60, hours: 0.5, charging: true)]
        let forecast = try XCTUnwrap(Forecaster.forecast(samples, percent: 60, isCharging: true,
                                                         now: start.addingTimeInterval(0.5 * 3600)))
        XCTAssertEqual(forecast.kind, .full)
        XCTAssertEqual(forecast.date.timeIntervalSince(start) / 3600, 0.5 + 2, accuracy: 0.01)
        XCTAssertNil(Forecaster.forecast(samples, percent: 100, isCharging: true, now: start))
    }

    func testUsageForecast() throws {
        // Marked charged two days ago and used 2 hours a day: 4 of 100 hours used, so 96%
        // left, which lasts 48 more days at 2 hours a day.
        let now = start.addingTimeInterval(48 * 3600)
        var log = UsageLog(macID: "mac-a", macName: "A")
        log.charges = [ChargeMark(device: "bt:kb", date: start, ranOut: false, mac: "mac-a", minutesBefore: 0)]
        for hour in [2, 3, 26, 27] { log.minutes["bt:kb", default: [:]][String(UsageLog.hour(start) + hour)] = 60 }
        let forecast = try XCTUnwrap(Estimator.forecast(for: "bt:kb", logs: [log], now: now))
        XCTAssertEqual(forecast.basis, .usage)
        XCTAssertEqual(forecast.date.timeIntervalSince(now) / 86400, 48, accuracy: 0.01)
        XCTAssertNil(Estimator.forecast(for: "bt:kb", logs: [log], now: start.addingTimeInterval(12 * 3600)),
                     "needs a day of use first")
    }

    func testText() {
        let now = start
        XCTAssertEqual(Forecast(kind: .empty, date: now.addingTimeInterval(3 * 86400), basis: .rate).shortText(now: now), "3d left")
        XCTAssertEqual(Forecast(kind: .empty, date: now.addingTimeInterval(5 * 3600), basis: .rate).text(now: now), "About 5 hours left")
        XCTAssertEqual(Forecast(kind: .full, date: now.addingTimeInterval(40 * 60), basis: .rate).shortText(now: now), "full in 40m")
        XCTAssertEqual(Forecast(kind: .full, date: now.addingTimeInterval(60), basis: .rate).text(now: now), "Full in about 1 minute")
    }
}
