import AppKit

// `batterylens <command>` (the app binary under a short name): run it against the running app
// and exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

// Top-level code isn't main-actor isolated in Swift 5 mode, though it runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock && !AgentSocket.isTestRun ? .regular : .accessory)
    app.run()
}
