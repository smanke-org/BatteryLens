#if DEBUG
import AppKit
import BatteryLensKit

/// Debug builds only. `BATTERYLENS_DEBUG_UPDATE_NOTES=<folder>`: fetches the notes of
/// BatteryLens's own releases, draws the update prompt, the What's New sheet Settings shows
/// after an automatic update, and Settings itself to PNGs, writes report.txt, and quits. It
/// starts nothing else: made-up devices only, no source, sync or updater. BatteryLens keeps
/// its settings in the standard defaults, so run it under a test bundle identifier.
@MainActor
enum DebugUpdateNotes {
    private static var keep: [AnyObject] = []

    static func run(folder: String) {
        guard Bundle.main.bundleIdentifier != "com.smanke.BatteryLens" else {
            NSLog("BatteryLens: run the update-notes test under a test bundle identifier")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }

        let hub = BatteryHub(sources: [DebugShots.SampleSource()], store: DeviceStore(fileURL: nil),
                             history: ChargeHistory(fileURL: out.appending(path: "history.jsonl"), now: Date()))
        hub.start()
        let model = AppModel(hub: hub)
        hub.onChange = { _ in model.devicesChanged() }
        let controller = SettingsWindowController(model: model)
        keep = [hub, model, controller]
        func contentSize() -> CGSize {
            controller.debugWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }

        Task {
            note("running \(AppInfo.labeledVersion) as \(Bundle.main.bundleIdentifier ?? "?")")
            // The update prompt, as someone on 1.0.3 would see it offered 1.0.6.
            let notes = await ReleaseNotes.fetch(newAfter: "1.0.3", through: "1.0.6")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.0.6", current: "1.0.3", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "1.0.5"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            SettingsWindowController.chosenSize = nil
            controller.show(tab: .general)
            try? await Task.sleep(for: .seconds(4))
            render(controller.debugWindow?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(controller.debugWindow?.attachedSheet != nil)")
            if let window = controller.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(for: .seconds(1))
            render(controller.debugWindow, to: out.appending(path: "general.png"))
            let window = controller.debugWindow
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) max \(window?.contentMaxSize ?? .zero) general content \(contentSize())")
            // A drag to 100 x 100 is held at the smallest the tab allows.
            if let window, let held = window.delegate?.windowWillResize?(window, to: NSSize(width: 100, height: 100)) {
                note("drag to 100x100 held at content \(window.contentRect(forFrameRect: NSRect(origin: .zero, size: held)).size)")
            }

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            SettingsWindowController.current?.showWhatsNew()
            try? await Task.sleep(for: .seconds(3))
            render(controller.debugWindow?.attachedSheet, to: out.appending(path: "whats-new-asked.png"))
            note("asked sheet shown: \(controller.debugWindow?.attachedSheet != nil)")
            if let window = controller.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Each tab opens at its own height until the user drags a size, then every tab uses that.
            controller.show(tab: .alerts)
            try? await Task.sleep(for: .seconds(2))
            note("alerts natural content \(contentSize())")
            SettingsWindowController.chosenSize = NSSize(width: 720, height: 520)
            controller.show(tab: .menuBar)
            try? await Task.sleep(for: .seconds(2))
            render(controller.debugWindow, to: out.appending(path: "menubar-dragged.png"))
            note("menu bar after a chosen 720x520: \(contentSize())")
            controller.show(tab: .devices)
            try? await Task.sleep(for: .seconds(2))
            note("devices after a chosen 720x520: \(contentSize())")
            SettingsWindowController.chosenSize = nil
            note("done")
            exit(0)
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
