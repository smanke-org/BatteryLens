import AppIntents
import BatteryLensShared
import SwiftUI
import WidgetKit

// The Device Batteries widget: rings or bars, chosen per widget when editing it, for
// every connected device or the ones picked. It reads the snapshot the app writes to
// the App Group; the app asks WidgetKit to reload when something visible changes.

@main
struct BatteryLensWidgets: WidgetBundle {
    var body: some Widget {
        DevicesWidget()
    }
}

struct DevicesWidget: Widget {
    /// Never change it: widgets already placed are found by their kind, and renaming it
    /// leaves every one of them blank (CHSErrorDomain 1100). The widget service also
    /// caches each widget's description for a while after an update, so a widget added
    /// right after one can get the previous version's configuration.
    static let kind = "Devices"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: DevicesConfiguration.self, provider: Provider()) { entry in
            DevicesView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Device Batteries")
        .description("Battery levels of your Mac and connected devices, as rings or bars.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Configuration

enum WidgetStyle: String, AppEnum {
    case rings, bars

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] = [
        .rings: "Rings",
        .bars: "Bars with Numbers",
    ]
}

struct DevicesConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Device Batteries"
    static let description = IntentDescription("Choose how the widget looks and which devices it shows.")

    @Parameter(title: "Style", default: .rings)
    var style: WidgetStyle

    @Parameter(title: "Devices", description: "Leave empty to show every connected device.")
    var devices: [DeviceEntity]?

    @Parameter(title: "Include Disconnected Devices", default: false)
    var includeDisconnected: Bool

    init() {}

    init(style: WidgetStyle) {
        self.style = style
    }
}

/// A device the widget can be set to show, from the app's latest snapshot.
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    let id: String
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(_ device: DeviceBattery) {
        id = device.id
        name = device.name
        symbol = device.kind.symbol
    }
}

struct DeviceQuery: EntityQuery {
    private var all: [DeviceEntity] { (SharedContainer.readSnapshot()?.devices ?? []).map(DeviceEntity.init) }

    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        let all = all
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [DeviceEntity] { all }
}

/// Tapping it tells the app that a device with an estimated level was just charged.
struct MarkChargedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark as Charged"
    static let isDiscoverable = false

    @Parameter(title: "Device ID")
    var deviceID: String

    init() {}

    init(deviceID: String) {
        self.deviceID = deviceID
    }

    func perform() async throws -> some IntentResult {
        WidgetRequests.send(.init(action: .markCharged, deviceID: deviceID))
        SharedContainer.log("widget: marked \(deviceID) charged")
        return .result()
    }
}

// MARK: - Timeline

struct DevicesEntry: TimelineEntry {
    let date: Date
    /// Nil when the App Group can't be read: shown as such rather than as "no devices".
    let snapshot: Snapshot?
    let configuration: DevicesConfiguration

    /// The devices this widget shows, in the order it shows them.
    var devices: [DeviceBattery] {
        guard let snapshot else { return [] }
        if let chosen = configuration.devices, !chosen.isEmpty {
            return chosen.compactMap { entity in snapshot.devices.first { $0.id == entity.id } }
        }
        return snapshot.devices.filter { device in
            device.isConnected || (configuration.includeDisconnected && !device.levels.isEmpty)
        }
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DevicesEntry {
        DevicesEntry(date: Date(), snapshot: .sample, configuration: DevicesConfiguration())
    }

    func snapshot(for configuration: DevicesConfiguration, in context: Context) async -> DevicesEntry {
        let snapshot = SharedContainer.readSnapshot()
        return DevicesEntry(date: Date(), snapshot: context.isPreview ? snapshot ?? .sample : snapshot,
                            configuration: configuration)
    }

    func timeline(for configuration: DevicesConfiguration, in context: Context) async -> Timeline<DevicesEntry> {
        let snapshot = SharedContainer.readSnapshot()
        // The log records each run, to see how often WidgetKit really reloads.
        let state = snapshot.map { "\($0.devices.count) devices, written \(Int(-$0.written.timeIntervalSinceNow)) s ago" }
            ?? (SharedContainer.url == nil ? "App Group unavailable" : "no snapshot readable")
        SharedContainer.log("widget: timeline \(context.family) \(configuration.style.rawValue) — \(state)")
        // A fallback refresh; the app asks for reloads when something changes.
        return Timeline(entries: [DevicesEntry(date: Date(), snapshot: snapshot, configuration: configuration)],
                        policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

// MARK: - Views

struct DevicesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DevicesEntry

    var body: some View {
        if entry.snapshot == nil {
            message("Open BatteryLens to start")
        } else if entry.devices.isEmpty {
            message(entry.configuration.devices?.isEmpty == false ? "The chosen devices aren't available" : "No battery devices connected")
        } else {
            switch entry.configuration.style {
            case .rings: RingsView(family: family, devices: entry.devices, snapshot: entry.snapshot)
            case .bars: BarsView(family: family, devices: entry.devices, snapshot: entry.snapshot)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
