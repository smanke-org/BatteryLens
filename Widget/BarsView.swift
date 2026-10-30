import AppIntents
import BatteryLensShared
import SwiftUI
import WidgetKit

struct BarsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DevicesEntry

    private var rowsPerColumn: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 8
        }
    }

    private var columns: Int { family == .systemExtraLarge ? 2 : 1 }

    var body: some View {
        let devices = Array(entry.devices.prefix(rowsPerColumn * columns))
        let compact = family == .systemSmall
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(0..<columns, id: \.self) { column in
                    let slice = devices.dropFirst(column * rowsPerColumn).prefix(rowsPerColumn)
                    VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                        ForEach(Array(slice)) { BarRow(device: $0, compact: compact) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            if !compact { UpdatedLine(snapshot: entry.snapshot) }
        }
    }
}

struct BarRow: View {
    let device: DeviceBattery
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: device.kind.symbol)
                    .frame(width: 16)
                Text(device.name)
                    .lineLimit(1)
                if !device.isConnected && !compact {
                    // Last-known levels: say how old they are.
                    Text(device.updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let forecast = device.forecast, !compact {
                    Text(forecast.shortText())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if device.isCharging { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
                Text(levelText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if device.isEstimated && !compact {
                    Button(intent: MarkChargedIntent(deviceID: device.id)) {
                        Image(systemName: "bolt.badge.checkmark")
                    }
                    .buttonStyle(.plain)
                    .help("Mark as charged")
                }
            }
            .font(compact ? .caption : .callout)
            if let lowest = device.lowest {
                LevelBar(percent: lowest, threshold: device.threshold, estimated: device.isEstimated)
            }
        }
        .opacity(device.isConnected ? 1 : 0.5)
    }

    private var levelText: String {
        guard !device.levels.isEmpty else { return "—" }
        let prefix = device.isEstimated ? "~" : ""
        if compact || device.levels.count == 1 { return device.lowest.map { "\(prefix)\($0)%" } ?? "—" }
        return device.levels.map { ($0.part.map { "\($0.shortName) " } ?? "") + "\($0.percent)" }.joined(separator: " · ")
    }
}

struct LevelBar: View {
    let percent: Int
    let threshold: Int
    var estimated = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(levelColor(percent, threshold: threshold).opacity(estimated ? 0.55 : 1))
                    .frame(width: max(4, geometry.size.width * CGFloat(percent) / 100))
                    .widgetAccentable()
            }
        }
        .frame(height: 4)
    }
}
