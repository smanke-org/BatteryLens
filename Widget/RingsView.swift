import BatteryLensShared
import SwiftUI
import WidgetKit

/// One ring: a device's level, or an earbud case's, which gets a ring of its own.
struct RingItem: Identifiable {
    let id: String
    let deviceID: String
    let symbol: String
    let name: String
    let percent: Int?
    let isCharging: Bool
    let isConnected: Bool
    let threshold: Int
    let isEstimated: Bool

    /// A device's ring, plus a second one for an earbud case.
    static func items(for devices: [DeviceBattery]) -> [RingItem] {
        devices.flatMap { device -> [RingItem] in
            let buds = device.levels.filter { $0.part != .chargingCase }
            var items = [RingItem(id: device.id, deviceID: device.id, symbol: device.kind.symbol, name: device.name,
                                  percent: buds.map(\.percent).min(),
                                  isCharging: buds.contains { $0.isCharging }, isConnected: device.isConnected,
                                  threshold: device.threshold, isEstimated: device.isEstimated)]
            if let chargingCase = device.levels.first(where: { $0.part == .chargingCase }) {
                let item = RingItem(id: device.id + "/case", deviceID: device.id, symbol: "airpodspro.chargingcase.wireless.fill",
                                    name: "\(device.name) Case", percent: chargingCase.percent,
                                    isCharging: chargingCase.isCharging, isConnected: device.isConnected,
                                    threshold: device.threshold, isEstimated: false)
                // A case reporting alone (buds away) is the device's only ring.
                if buds.isEmpty { items = [item] } else { items.append(item) }
            }
            return items
        }
    }
}

struct RingsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DevicesEntry

    private var layout: (columns: Int, rows: Int, diameter: CGFloat, names: Bool) {
        switch family {
        case .systemSmall: (2, 2, 46, false)
        case .systemMedium: (4, 1, 56, true)
        case .systemLarge: (4, 3, 56, true)
        default: (6, 3, 60, true)
        }
    }

    var body: some View {
        let layout = layout
        let items = Array(RingItem.items(for: entry.devices).prefix(layout.columns * layout.rows))
        VStack(spacing: 0) {
            Grid(horizontalSpacing: 8, verticalSpacing: family == .systemSmall ? 8 : 12) {
                ForEach(0..<rowCount(items.count, layout.columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            if index < items.count {
                                RingCell(item: items[index], diameter: layout.diameter, showsName: layout.names)
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if family == .systemLarge || family == .systemExtraLarge {
                UpdatedLine(snapshot: entry.snapshot)
            }
        }
    }

    private func rowCount(_ count: Int, _ columns: Int) -> Int { max(1, (count + columns - 1) / columns) }
}

struct RingCell: View {
    let item: RingItem
    let diameter: CGFloat
    let showsName: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: diameter * 0.11)
                Circle()
                    .trim(from: 0, to: CGFloat(item.percent ?? 0) / 100)
                    .stroke(levelColor(item.percent, threshold: item.threshold),
                            style: StrokeStyle(lineWidth: diameter * 0.11, lineCap: .round, dash: item.isEstimated ? [3, 4] : []))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                Image(systemName: item.symbol)
                    .font(.system(size: diameter * 0.32))
                    .foregroundStyle(.primary)
                if item.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: diameter * 0.2, weight: .bold))
                        .foregroundStyle(.green)
                        .offset(y: -diameter / 2)
                }
            }
            .frame(width: diameter, height: diameter)
            .padding(diameter * 0.055)

            Text(percentText)
                .font(.system(size: showsName ? 13 : 12, weight: .semibold))
                .monospacedDigit()
            if showsName {
                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: diameter + 24)
            }
        }
        .opacity(item.isConnected ? 1 : 0.5)
    }

    private var percentText: String {
        guard let percent = item.percent else { return "—" }
        return (item.isEstimated ? "~" : "") + "\(percent)%"
    }
}
