#if DEBUG
import AppKit
import BatteryLensKit
import BatteryLensShared
import SwiftUI
import WidgetKit

/// `BATTERYLENS_DEBUG_SHOTS=<folder>`: pictures for the website and README, made from
/// made-up devices so no real device or setting shows. Draws the widget's views and the
/// Settings window offscreen into PNGs, then quits. Nothing is saved: the store and the
/// history live in memory or a temporary file, and no source, sync or updater starts.
@MainActor
enum DebugShots {
    private static var keep: [AnyObject] = []

    static func run(folder: String) {
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let now = Date()
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("batterylens-shots-history.jsonl")
        try? sampleHistory(now: now).write(to: historyURL, atomically: true, encoding: .utf8)
        let hub = BatteryHub(sources: [SampleSource()], store: DeviceStore(fileURL: nil),
                             history: ChargeHistory(fileURL: historyURL, now: now))
        hub.start()
        let model = AppModel(hub: hub)
        hub.onChange = { _ in model.devicesChanged() }
        keep = [hub, model]

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let snapshot = Snapshot(devices: hub.devices, written: now.addingTimeInterval(-60), appVersion: "shots")
                for style in ["rings", "bars"] {
                    for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge] {
                        widget(style: style, family: family, snapshot: snapshot,
                               to: out.appendingPathComponent("widget-\(style)-\(name(family)).png"))
                    }
                }
                settings(model: model, out: out)
                try? FileManager.default.removeItem(at: historyURL)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Widget

    private static func name(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        default: "xl"
        }
    }

    /// The desktop widget sizes on macOS, in points.
    private static func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        default: CGSize(width: 769, height: 382)
        }
    }

    private static func widget(style: String, family: WidgetFamily, snapshot: Snapshot, to url: URL) {
        let devices = snapshot.devices.filter(\.isConnected)
        let content = Group {
            if style == "rings" {
                RingsView(family: family, devices: devices, snapshot: snapshot)
            } else {
                BarsView(family: family, devices: devices, snapshot: snapshot)
            }
        }
        let view = content
            .padding(16)
            .frame(width: size(family).width, height: size(family).height)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        write(NSBitmapImageRep(cgImage: image), to: url)
    }

    // MARK: - Settings

    private static func settings(model: AppModel, out: URL) {
        DevicesTab.height = 660
        let controller = SettingsWindowController(model: model)
        keep.append(controller)
        let shots: [(SettingsTab, String, String?)] = [
            (.devices, "settings-mouse", "bt:aa:01"),
            (.devices, "settings-keyboard", "bt:aa:03"),
            (.general, "settings-general", nil),
            (.alerts, "settings-alerts", nil),
        ]
        for (tab, file, device) in shots {
            if let device { model.selectedDevice = device }
            controller.show(tab: tab)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            guard let window = NSApp.windows.first(where: { $0.title == "BatteryLens Settings" }),
                  let frame = window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            write(rep, to: out.appendingPathComponent("\(file).png"))
        }
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Made-up devices

    /// Placeholder names only.
    final class SampleSource: BatterySource {
        let kind = SourceKind.powerList
        let status = "sample"
        var onReadings: (([BatteryReading]) -> Void)?

        func start() {
            onReadings?([
                BatteryReading(keys: ["mac:internal"], name: "MacBook Pro", kind: .mac, percent: 76, source: .powerList),
                BatteryReading(keys: ["bt:aa:02", "group:sample"], name: "Earbuds", kind: .earbuds, part: .left,
                               percent: 82, source: .powerList),
                BatteryReading(keys: ["bt:aa:02", "group:sample"], name: "Earbuds", kind: .earbuds, part: .right,
                               percent: 80, source: .powerList),
                BatteryReading(keys: ["bt:aa:02", "group:sample"], name: "Earbuds", kind: .earbuds, part: .chargingCase,
                               percent: 64, source: .powerList),
                BatteryReading(keys: ["bt:aa:01"], name: "Mouse", kind: .mouse, percent: 52, source: .logitech),
                BatteryReading(keys: ["bt:aa:03"], name: "Keyboard", kind: .keyboard, percent: 72, source: .estimate),
                BatteryReading(keys: ["bt:aa:04"], name: "Trackpad", kind: .trackpad, percent: 14, source: .powerList),
                BatteryReading(keys: ["gc:sample"], name: "Game Controller", kind: .controller, percent: 46,
                               isCharging: true, source: .controller),
                BatteryReading(keys: ["bt:aa:05"], name: "Headphones", kind: .headphones, percent: 91, source: .ble),
            ])
        }

        func refresh() {}
    }

    /// A week of the mouse running down with a charge in the middle, the trackpad
    /// running low, the keyboard's estimate, and the controller charging now.
    private static func sampleHistory(now: Date) -> String {
        var lines: [String] = []
        func add(_ device: String, _ percent: Int, hoursAgo: Double, charging: Bool = false) {
            let date = now.addingTimeInterval(-hoursAgo * 3600).formatted(.iso8601)
            lines.append("{\"device\":\"\(device)\",\"percent\":\(percent),\"isCharging\":\(charging),\"date\":\"\(date)\"}")
        }
        // Mouse: 90% a week ago, down to 37%, charged to 100%, now 52%.
        for (index, hours) in stride(from: 168.0, through: 100, by: -4).enumerated() { add("bt:aa:01", 90 - index * 3 - (index % 3), hoursAgo: hours) }
        add("bt:aa:01", 45, hoursAgo: 99, charging: true)
        add("bt:aa:01", 100, hoursAgo: 97, charging: true)
        for (index, hours) in stride(from: 96.0, through: 1, by: -4).enumerated() { add("bt:aa:01", 100 - index * 2 + (index % 2), hoursAgo: hours) }
        add("bt:aa:01", 52, hoursAgo: 0.5)
        // Trackpad: running low over the week.
        for (index, hours) in stride(from: 160.0, through: 2, by: -8).enumerated() { add("bt:aa:04", 60 - index * 2 - (index % 2), hoursAgo: hours) }
        add("bt:aa:04", 14, hoursAgo: 1)
        // Keyboard estimate: charged five days ago.
        for (index, hours) in stride(from: 120.0, through: 2, by: -6).enumerated() { add("bt:aa:03", 100 - (index * 3) / 2, hoursAgo: hours) }
        add("bt:aa:03", 72, hoursAgo: 1)
        // Controller: charging for the last half hour.
        add("gc:sample", 20, hoursAgo: 0.6, charging: true)
        add("gc:sample", 46, hoursAgo: 0.02, charging: true)
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
