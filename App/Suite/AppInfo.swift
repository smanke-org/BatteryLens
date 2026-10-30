import Foundation

/// Version details read from the bundle, so the number shown in the menu and in
/// Settings always matches what was actually built rather than a hardcoded copy.
enum AppInfo {
    static let name = "BatteryLens"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// "1.0.1 (12)": for logs and the snapshot.
    static var versionString: String { "\(version) (\(build))" }

    /// "v1.0.1", or "v1.0.1 (12)" when the build number has moved past the
    /// marketing version.
    static var displayVersion: String {
        (version == build ? "v\(version)" : "v\(version) (\(build))") + (stage.map { " \($0)" } ?? "")
    }

    /// "beta" while BatteryLens is in beta (BatteryLensReleaseStage in Info.plist).
    static var stage: String? {
        Bundle.main.infoDictionary?["BatteryLensReleaseStage"] as? String
    }
}
