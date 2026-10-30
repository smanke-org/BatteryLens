import AppKit

// Top-level code isn't main-actor isolated in Swift 5 mode, though it runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}
