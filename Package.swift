// swift-tools-version: 6.2
import PackageDescription

// The logic lives here so `swift test` runs it without Xcode. project.yml (XcodeGen)
// builds the app and the widget extension, which need an Xcode build.
//
// BatteryLensShared: models and the App Group snapshot; the only part the sandboxed
//                    widget links, so it never pulls in IOKit or Bluetooth.
// BatteryLensKit:    the battery sources and the merging, used by the app.
let package = Package(
    name: "BatteryLensKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BatteryLensShared", targets: ["BatteryLensShared"]),
        .library(name: "BatteryLensKit", targets: ["BatteryLensKit"]),
    ],
    targets: [
        .target(name: "BatteryLensShared", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "BatteryLensKit", dependencies: ["BatteryLensShared"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BatteryLensKitTests", dependencies: ["BatteryLensKit", "BatteryLensShared"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
