import Foundation
import os

/// The App Group folder the app and the widget share: the app writes snapshot.json,
/// the widget reads it. Both append to activity.log, which shows when the app asked
/// the widget to reload and when WidgetKit actually ran the widget.
///
/// macOS protects group containers from other apps, so a shell can't read the folder;
/// every log line also goes to the unified log, readable with
/// `log show --predicate 'subsystem == "com.smanke.BatteryLens"' --last 1h`.
public enum SharedContainer {
    public static let logger = Logger(subsystem: "com.smanke.BatteryLens", category: "activity")
    /// Team-prefixed, so a Developer ID app can use it without a provisioning profile.
    public static let groupID = "32CWL275JJ.com.smanke.BatteryLens"
    private static let maxLogLines = 1000

    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static var snapshotURL: URL? { url?.appendingPathComponent("snapshot.json") }
    public static var logURL: URL? { url?.appendingPathComponent("activity.log") }

    public static func write(_ snapshot: Snapshot) throws {
        guard let snapshotURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    public static func readSnapshot() -> Snapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        guard let logURL else { return }
        let line = "\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))) \(message)\n"
        // Appends are small single writes, so the two processes don't interleave lines.
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    /// Newest last.
    public static func logLines() -> [String] {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Keeps the log short; called by the app at launch.
    public static func trimLog() {
        let lines = logLines()
        guard lines.count > maxLogLines, let logURL else { return }
        try? (lines.suffix(maxLogLines / 2).joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}
