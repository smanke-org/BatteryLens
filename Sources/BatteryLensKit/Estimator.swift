import BatteryLensShared
import Foundation

/// One Mac's record of how much each silent device was used, and when it was charged.
/// Each Mac running BatteryLens writes its own, to iCloud Drive when it's on, so a
/// keyboard shared between your Macs is counted on all of them.
public struct UsageLog: Codable, Hashable, Sendable {
    public var macID: String
    public var macName: String
    /// Device key → hour (hours since 1970, so time zones don't matter) → minutes in
    /// that hour with any input from the device.
    public var minutes: [String: [String: Int]]
    public var charges: [ChargeMark]
    public var updated: Date

    public init(macID: String, macName: String, minutes: [String: [String: Int]] = [:], charges: [ChargeMark] = [],
                updated: Date = Date()) {
        self.macID = macID
        self.macName = macName
        self.minutes = minutes
        self.charges = charges
        self.updated = updated
    }

    public static func hour(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 3600)) }

    public mutating func addMinute(_ device: String, at date: Date) {
        let key = String(Self.hour(date))
        minutes[device, default: [:]][key] = min(60, (minutes[device]?[key] ?? 0) + 1)
    }

    /// Drops usage from hours before `cutoff`, keeping the file small.
    public mutating func prune(before cutoff: Date) {
        let first = Self.hour(cutoff)
        for device in minutes.keys {
            minutes[device] = minutes[device]?.filter { (Int($0.key) ?? 0) >= first }
            if minutes[device]?.isEmpty == true { minutes[device] = nil }
        }
    }
}

/// "I just charged it", optionally with "it had run out", which is what teaches the
/// estimator how long a charge lasts.
public struct ChargeMark: Codable, Hashable, Sendable {
    public var device: String
    public var date: Date
    public var ranOut: Bool
    /// The Mac it was marked on, and that Mac's minutes of use earlier in the same hour,
    /// so the hour of the charge splits exactly into before and after on that Mac.
    public var mac: String?
    public var minutesBefore: Int?

    public init(device: String, date: Date, ranOut: Bool, mac: String? = nil, minutesBefore: Int? = nil) {
        self.device = device
        self.date = date
        self.ranOut = ranOut
        self.mac = mac
        self.minutesBefore = minutesBefore
    }
}

/// Estimates the level of a device that never reports one, from active use since it
/// was last marked charged: 100% minus the share of a charge that much use takes.
///
/// How many hours of use a charge lasts starts as a guess and is learned each time
/// the device runs out: that charge's hours of use, averaged over the last few.
public enum Estimator {
    /// The starting guess, until a charge has been used up.
    public static let defaultHoursPerCharge: Double = 100
    static let learnedCycles = 3

    public struct Estimate: Hashable, Sendable {
        public var percent: Int
        public var chargedAt: Date
        public var activeMinutes: Int
        public var hoursPerCharge: Double
        /// How many run-down charges `hoursPerCharge` was learned from; 0 means it's the guess.
        public var learnedFrom: Int
    }

    public static func charges(for device: String, in logs: [UsageLog]) -> [ChargeMark] {
        Array(Set(logs.flatMap { $0.charges.filter { $0.device == device } })).sorted { $0.date < $1.date }
    }

    public static func estimate(for device: String, logs: [UsageLog], now: Date = Date()) -> Estimate? {
        let marks = charges(for: device, in: logs)
        guard let last = marks.last else { return nil }
        let active = activeMinutes(device, logs, from: last, to: now)
        let (hours, cycles) = hoursPerCharge(marks, device, logs)
        let used = Double(active) / 60 / hours * 100
        let percent = max(0, min(100, Int((100 - used).rounded())))
        return Estimate(percent: percent, chargedAt: last.date, activeMinutes: active, hoursPerCharge: hours,
                        learnedFrom: cycles)
    }

    /// Active minutes from every Mac between a charge mark and `to` (a later mark, or now).
    ///
    /// Use is kept per hour, so the hours a period starts and ends in are split: on the
    /// Mac a mark was made on, by the minutes it had counted when marked; on other Macs,
    /// in proportion to the time on each side.
    static func activeMinutes(_ device: String, _ logs: [UsageLog], from start: ChargeMark, to end: Date,
                              endMark: ChargeMark? = nil) -> Int {
        guard end > start.date else { return 0 }
        let firstHour = UsageLog.hour(start.date), lastHour = UsageLog.hour(end)
        func fraction(_ date: Date) -> Double {
            date.timeIntervalSince1970 / 3600 - Double(UsageLog.hour(date))
        }
        var total = 0.0
        for log in logs {
            let buckets = log.minutes[device] ?? [:]
            func bucket(_ hour: Int) -> Double { Double(buckets[String(hour)] ?? 0) }
            // Minutes in the start hour that came before the mark, and in the end hour before the end.
            func beforeStart() -> Double {
                if start.mac == log.macID, let before = start.minutesBefore { return min(Double(before), bucket(firstHour)) }
                return bucket(firstHour) * fraction(start.date)
            }
            func beforeEnd() -> Double {
                if let endMark {
                    if endMark.mac == log.macID, let before = endMark.minutesBefore { return min(Double(before), bucket(lastHour)) }
                    return bucket(lastHour) * fraction(end)
                }
                return bucket(lastHour) // Now: everything counted so far came before it.
            }
            if firstHour == lastHour {
                total += max(0, beforeEnd() - beforeStart())
                continue
            }
            total += bucket(firstHour) - beforeStart() + beforeEnd()
            for (key, minutes) in buckets {
                guard let hour = Int(key), hour > firstHour, hour < lastHour else { continue }
                total += Double(minutes)
            }
        }
        return Int(total.rounded())
    }

    static func hoursPerCharge(_ marks: [ChargeMark], _ device: String, _ logs: [UsageLog]) -> (Double, Int) {
        var learned: [Double] = []
        for (previous, next) in zip(marks, marks.dropFirst()) where next.ranOut {
            let hours = Double(activeMinutes(device, logs, from: previous, to: next.date, endMark: next)) / 60
            // A charge that "ran out" after almost no use was probably a mistaken tap.
            if hours >= 1 { learned.append(hours) }
        }
        let recent = learned.suffix(learnedCycles)
        guard !recent.isEmpty else { return (defaultHoursPerCharge, 0) }
        return (recent.reduce(0, +) / Double(recent.count), recent.count)
    }
}
