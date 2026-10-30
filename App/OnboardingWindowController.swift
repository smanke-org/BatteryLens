import AppKit
import SwiftUI

/// The first-launch window: what BatteryLens does, each permission explained before
/// macOS asks for it, and how to add the widget.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    var onFinish: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let view = OnboardingView(model: model) { [weak self] in self?.window?.close() }
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to BatteryLens"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            let size = NSHostingView(rootView: OnboardingView(model: model) {}).fittingSize
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window.setContentSize(NSSize(width: OnboardingView.width, height: min(ceil(size.height), available)))
            window.center()
            self.window = window
        }
        model.watchPermissions(true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.watchPermissions(false)
        onFinish?()
    }
}

struct OnboardingView: View {
    static let width: CGFloat = 560

    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to BatteryLens").font(.title2.weight(.semibold))
                        Text("Battery levels for your Mac and everything connected to it, in the menu bar and a desktop widget.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("These permissions let BatteryLens read more devices. All are optional, and you can change them later in Settings › Permissions.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Permission.allCases) { PermissionRow(model: model, permission: $0) }
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add the widget").font(.headline)
                    Text("Right-click the desktop, choose Edit Widgets, search for BatteryLens and drag Device Batteries onto the desktop.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: Self.width)
    }
}
