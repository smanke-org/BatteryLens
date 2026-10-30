import BatteryLensShared
import Foundation
import IOKit.ps

/// When a battery runs out or finishes charging, from its charge history: the current
/// discharge (or charge) once it has gone on long enough to measure, else the average
/// of recent ones. The Mac's own battery uses macOS's figure.
public enum Forecaster {
    /// A discharge is measured once it has dropped this much over at least this long.
    static let minimumDrop = 5
    static let minimumDrainSpan: TimeInterval = 3600
    static let minimumRise = 3
    static let minimumChargeSpan: TimeInterval = 10 * 60
    /// Past runs older than this aren't averaged in.
    static let lookback: TimeInterval = 30 * 24 * 3600
    /// Further out than this, a forecast says more about the data than the battery.
    static let longestEmpty: TimeInterval = 90 * 24 * 3600
    static let longestFull: TimeInterval = 2 * 24 * 3600

    /// One stretch of discharging or charging in a battery's history.
    struct Run {
        var isCharging: Bool
        var samples: [ChargeHistory.Sample]
    }

    /// Splits a battery's samples into runs: a new one starts when charging starts or
    /// stops, or when the level jumps up while not charging (charged while switched off).
    static func runs(_ samples: [ChargeHistory.Sample]) -> [Run] {
        var runs: [Run] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            if var run = runs.last, run.isCharging == sample.isCharging,
               run.isCharging || sample.percent < (run.samples.last?.percent ?? 0) + minimumRise {
                run.samples.append(sample)
                runs[runs.count - 1] = run
            } else {
                runs.append(Run(isCharging: sample.isCharging, samples: [sample]))
            }
        }
        return runs
    }

    /// From the battery's history, with its current level.
    public static func forecast(_ samples: [ChargeHistory.Sample], percent: Int, isCharging: Bool,
                                now: Date = Date()) -> Forecast? {
        if isCharging, percent >= 100 { return nil }
        if !isCharging, percent <= 0 { return nil }
        let all = runs(samples)
        let minimumChange = isCharging ? minimumRise : minimumDrop
        let minimumSpan = isCharging ? minimumChargeSpan : minimumDrainSpan

        // Percent per second: the current run when it's long enough, else recent past ones.
        var rate: Double?
        if let current = all.last, current.isCharging == isCharging, let first = current.samples.first {
            let change = abs(percent - first.percent)
            let span = now.timeIntervalSince(first.date)
            if change >= minimumChange, span >= minimumSpan { rate = Double(change) / span }
        }
        if rate == nil {
            var change = 0, span: TimeInterval = 0
            // A finished run lasted until the next one began.
            for (index, run) in all.enumerated().dropLast() where run.isCharging == isCharging {
                guard let first = run.samples.first, let last = run.samples.last,
                      now.timeIntervalSince(first.date) <= lookback else { continue }
                let runChange = abs(last.percent - first.percent)
                let runSpan = all[index + 1].samples[0].date.timeIntervalSince(first.date)
                guard runChange >= minimumChange, runSpan >= minimumSpan else { continue }
                change += runChange
                span += runSpan
            }
            if change > 0, span > 0 { rate = Double(change) / span }
        }
        guard let rate, rate > 0 else { return nil }

        let seconds = Double(isCharging ? 100 - percent : percent) / rate
        guard seconds <= (isCharging ? longestFull : longestEmpty) else { return nil }
        return Forecast(kind: isCharging ? .full : .empty, date: now.addingTimeInterval(seconds), basis: .rate)
    }

    /// macOS's own estimate for the Mac's battery; nil while it's still working one out,
    /// or on power and not charging.
    public static func systemForecast(now: Date = Date()) -> Forecast? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            guard charging || onBattery, let minutes = description[key] as? Int, minutes > 0 else { return nil }
            return Forecast(kind: charging ? .full : .empty, date: now.addingTimeInterval(Double(minutes) * 60),
                            basis: .system)
        }
        return nil
    }
}

extension Estimator {
    /// Usage is averaged over at most this long, and needs at least a day of it.
    static let usageWindow: TimeInterval = 14 * 24 * 3600
    static let minimumUsageWindow: TimeInterval = 24 * 3600

    /// When an estimated device runs out at your usual daily use of it: the hours of use
    /// left in its charge, spread over the minutes a day it has been used recently.
    public static func forecast(for device: String, logs: [UsageLog], now: Date = Date()) -> Forecast? {
        guard let estimate = estimate(for: device, logs: logs, now: now), estimate.percent > 0 else { return nil }
        let firstUse = logs.compactMap { $0.minutes[device]?.keys.compactMap(Int.init).min() }.min()
            .map { Date(timeIntervalSince1970: Double($0) * 3600) }
        let firstMark = charges(for: device, in: logs).first?.date
        guard let observedFrom = [firstUse, firstMark].compactMap({ $0 }).min() else { return nil }
        let start = max(observedFrom, now.addingTimeInterval(-usageWindow))
        let window = now.timeIntervalSince(start)
        guard window >= minimumUsageWindow else { return nil }

        let firstHour = UsageLog.hour(start)
        let minutes = logs.reduce(0) { total, log in
            total + (log.minutes[device] ?? [:]).reduce(0) { $0 + ((Int($1.key) ?? 0) >= firstHour ? $1.value : 0) }
        }
        guard minutes > 0 else { return nil }
        let perDay = Double(minutes) / (window / 86400)
        let minutesLeft = Double(estimate.percent) / 100 * estimate.hoursPerCharge * 60
        let seconds = minutesLeft / perDay * 86400
        guard seconds <= Forecaster.longestEmpty else { return nil }
        return Forecast(kind: .empty, date: now.addingTimeInterval(seconds), basis: .usage)
    }
}
