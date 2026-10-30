import BatteryLensShared
import Foundation

/// Turns every source's readings into one entry per physical device.
///
/// Readings that share an identifier belong together (the MX Master 4 is "MX Master 4 M"
/// in the power list and "MX Master 4 for Mac" over HID++, with one UUID). Readings with
/// the same name are joined too, unless both sides carry identifiers of the same type
/// that differ: that keeps two "MX Master 3S M" mice apart while joining AirPods from the
/// power list (UUIDs) with AirPods from System Information (an address).
public enum DeviceMerger {
    /// Whose name to show: the Bluetooth name you gave the device first.
    private static let namingOrder: [SourceKind] = [.profiler, .powerList, .ble, .hid, .controller, .logitech, .estimate]
    private static let strongKeyPrefixes = ["uuid:", "bt:", "logi:"]

    /// `knownIDs` maps identifiers to the ID their device had before, and is updated: a
    /// device keeps its ID when a source joins or drops out (System Information adds the
    /// address only every few minutes), instead of looking like a new device.
    public static func merge(_ readings: [BatteryReading], knownIDs: inout [String: String]) -> [DeviceBattery] {
        let devices = merge(readings)
        var taken = Set<String>()
        return devices.map { device -> DeviceBattery in
            var device = device
            if let id = device.keys.sorted().compactMap({ knownIDs[$0] }).first(where: { !taken.contains($0) }) {
                device.id = id
            }
            taken.insert(device.id)
            for key in device.keys { knownIDs[key] = device.id }
            return device
        }
    }

    public static func merge(_ readings: [BatteryReading]) -> [DeviceBattery] {
        var parent = Array(readings.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        var owner: [String: Int] = [:]
        for (i, reading) in readings.enumerated() {
            for key in reading.keys {
                if let j = owner[key] { union(i, j) } else { owner[key] = i }
            }
        }

        func groupKeys(_ root: Int) -> Set<String> {
            readings.indices.filter { find($0) == root }.reduce(into: Set<String>()) { $0.formUnion(readings[$1].keys) }
        }
        for i in readings.indices {
            for j in readings.indices where j > i && find(i) != find(j) {
                guard normalizedName(readings[i]) == normalizedName(readings[j]),
                      !conflict(groupKeys(find(i)), groupKeys(find(j))) else { continue }
                union(i, j)
            }
        }

        let groups = Dictionary(grouping: readings.indices) { find($0) }.values.map { $0.map { readings[$0] } }
        return sorted(groups.map(device))
    }

    /// The Mac first, then connected devices, then by name.
    public static func sorted(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        devices.sorted { a, b in
            if (a.kind == .mac) != (b.kind == .mac) { return a.kind == .mac }
            if a.isConnected != b.isConnected { return a.isConnected }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func normalizedName(_ reading: BatteryReading) -> String {
        var name = reading.name.lowercased().trimmingCharacters(in: .whitespaces)
        if reading.part == .chargingCase, name.hasSuffix(" case") { name.removeLast(5) }
        return name
    }

    /// Both groups name a different device of the same kind of identifier.
    private static func conflict(_ a: Set<String>, _ b: Set<String>) -> Bool {
        strongKeyPrefixes.contains { prefix in
            let left = a.filter { $0.hasPrefix(prefix) }, right = b.filter { $0.hasPrefix(prefix) }
            return !left.isEmpty && !right.isEmpty && left.isDisjoint(with: right)
        }
    }

    private static func device(from readings: [BatteryReading]) -> DeviceBattery {
        let keys = readings.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let named = readings.min { namingOrder.firstIndex(of: $0.source)! < namingOrder.firstIndex(of: $1.source)! }!
        var name = named.name
        if named.part == .chargingCase, name.lowercased().hasSuffix(" case") { name.removeLast(5) }
        let kind = readings.sorted { $0.source < $1.source }.first { $0.kind != .other }?.kind ?? .other

        var levels: [DeviceBattery.Level] = []
        let byPart = Dictionary(grouping: readings.filter { $0.percent != nil }) { $0.part }
        let partOrder: [BatteryPart?] = [nil, .left, .right, .chargingCase]
        for part in partOrder {
            guard let best = byPart[part]?.min(by: { a, b in
                a.source != b.source ? a.source < b.source : a.date > b.date
            }) else { continue }
            levels.append(.init(part: part, percent: best.percent!, isCharging: best.isCharging, source: best.source, date: best.date))
        }

        return DeviceBattery(id: stableID(keys: keys, name: name), name: name, kind: kind, keys: keys, levels: levels,
                             isConnected: readings.contains { $0.isConnected },
                             updated: readings.map(\.date).max() ?? Date())
    }

    /// Prefers the Bluetooth address, which every source that knows it agrees on.
    private static func stableID(keys: Set<String>, name: String) -> String {
        for prefix in ["bt:", "uuid:", "logi:", "group:", "mac:", "gc:"] {
            if let key = keys.filter({ $0.hasPrefix(prefix) }).sorted().first { return key }
        }
        return "name:\(name.lowercased())"
    }
}
