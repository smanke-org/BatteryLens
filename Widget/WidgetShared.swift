import BatteryLensShared
import SwiftUI

// Shared by the widget's views, which the app also draws for pictures of the widget.

/// "Updated 2 min ago", shown where there's room.
struct UpdatedLine: View {
    let snapshot: Snapshot?

    var body: some View {
        if let snapshot {
            Text("Updated \(snapshot.written, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// How a level is drawn: red at or below the device's low level, green otherwise.
func levelColor(_ percent: Int?, threshold: Int) -> Color {
    guard let percent else { return .secondary }
    return percent <= threshold ? .red : .green
}

extension DeviceBattery {
    /// True when the level shown is the app's estimate rather than a reading.
    var isEstimated: Bool { levels.contains { $0.source == .estimate } }
}
