import BatteryLensKit
import BatteryLensShared
import Charts
import SwiftUI

/// A device's levels over the last day, week or month, with charging shaded.
struct HistorySection: View {
    enum Range: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month"

        var id: Self { self }

        var seconds: TimeInterval {
            switch self {
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            case .month: 30 * 24 * 3600
            }
        }
    }

    /// One point of a battery's line.
    struct Point: Identifiable {
        let id = UUID()
        let series: String
        let date: Date
        let percent: Int
    }

    @ObservedObject var model: AppModel
    let device: DeviceBattery
    @AppStorage("historyRange") private var range = Range.week

    var body: some View {
        let now = Date()
        let from = now.addingTimeInterval(-range.seconds)
        let samples = model.history(for: device)
        let points = Self.points(samples, device: device, from: from, now: now)
        let charging = Self.chargingSpans(samples, device: device, from: from, now: now)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.callout.weight(.medium))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let forecast = device.forecast {
                Text(Self.describe(forecast))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if points.isEmpty {
                Text("No history yet. BatteryLens records the level whenever it changes while the device is connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                chart(points, charging: charging, from: from, now: now)
                    .frame(height: 150)
            }
        }
    }

    private func chart(_ points: [Point], charging: [(start: Date, end: Date)], from: Date, now: Date) -> some View {
        let multiple = Set(points.map(\.series)).count > 1
        return Chart {
            ForEach(Array(charging.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end),
                              yStart: .value("Low", 0), yEnd: .value("High", 100))
                    .foregroundStyle(.green.opacity(0.12))
            }
            RuleMark(y: .value("Low battery", device.threshold))
                .foregroundStyle(.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Level", point.percent),
                         series: .value("Battery", point.series))
                    // A level holds until the next reading: steps, never slopes between readings.
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Battery", point.series))
            }
        }
        .chartXScale(domain: from...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartLegend(multiple ? .visible : .hidden)
    }

    static func describe(_ forecast: Forecast) -> String {
        let basis = switch forecast.basis {
        case .system: "by macOS's estimate"
        case .rate: forecast.kind == .empty ? "at its recent rate of use" : "at its recent charging rate"
        case .usage: "at your usual daily use"
        }
        return "\(forecast.text()) \(basis)."
    }

    static func seriesName(_ part: BatteryPart?) -> String {
        switch part {
        case nil: "Battery"
        case .left: "Left"
        case .right: "Right"
        case .chargingCase: "Case"
        }
    }

    /// Each battery's samples in the range, starting from the level it had going in and
    /// carried on to its current level now.
    static func points(_ samples: [ChargeHistory.Sample], device: DeviceBattery, from: Date, now: Date) -> [Point] {
        var points: [Point] = []
        for part in Set(samples.map(\.part)).sorted(by: { seriesName($0) < seriesName($1) }) {
            let series = seriesName(part)
            let mine = samples.filter { $0.part == part }.sorted { $0.date < $1.date }
            let inRange = mine.filter { $0.date >= from }
            if let before = mine.last(where: { $0.date < from }) {
                points.append(Point(series: series, date: from, percent: before.percent))
            }
            points += inRange.map { Point(series: series, date: $0.date, percent: $0.percent) }
            guard let last = mine.last, last.date >= from || points.contains(where: { $0.series == series }) else { continue }
            let current = device.levels.first { $0.part == part }?.percent ?? last.percent
            // Disconnected: the line ends at the last reading instead of claiming the level held since.
            if device.isConnected { points.append(Point(series: series, date: now, percent: current)) }
        }
        return points
    }

    /// When the device's main battery (an earbud, not the case) was charging.
    static func chargingSpans(_ samples: [ChargeHistory.Sample], device: DeviceBattery, from: Date,
                              now: Date) -> [(start: Date, end: Date)] {
        let parts = Set(samples.map(\.part))
        let part = parts.contains(nil) ? nil : parts.filter { $0 != .chargingCase }.min { seriesName($0) < seriesName($1) }
        let mine = samples.filter { $0.part == part }.sorted { $0.date < $1.date }
        var spans: [(start: Date, end: Date)] = []
        var start: Date?
        for sample in mine {
            if sample.isCharging, start == nil { start = max(sample.date, from) }
            if !sample.isCharging, let began = start {
                if sample.date > from { spans.append((began, sample.date)) }
                start = nil
            }
        }
        if let start, device.isConnected { spans.append((start, now)) }
        return spans
    }
}
