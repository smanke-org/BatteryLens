import Foundation

/// Requests from the widget's buttons to the app. The widget is sandboxed and runs in
/// its own process, so it writes the request to the App Group and posts a Darwin
/// notification; the app reads and clears the queue when it hears it.
public enum WidgetRequests {
    public struct Request: Codable, Hashable, Sendable {
        public enum Action: String, Codable, Sendable { case markCharged }
        public var action: Action
        public var deviceID: String
        public var date: Date

        public init(action: Action, deviceID: String, date: Date = Date()) {
            self.action = action
            self.deviceID = deviceID
            self.date = date
        }
    }

    public static let notificationName = "com.smanke.BatteryLens.widgetRequest"
    private static var url: URL? { SharedContainer.url?.appendingPathComponent("requests.json") }

    public static func send(_ request: Request) {
        guard let url else { return }
        var queue = read()
        queue.append(request)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(queue).write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notificationName as CFString), nil, nil, true)
    }

    /// Everything waiting, oldest first; the queue is emptied.
    public static func take() -> [Request] {
        let queue = read()
        if !queue.isEmpty, let url { try? FileManager.default.removeItem(at: url) }
        return queue
    }

    private static func read() -> [Request] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Request].self, from: data)) ?? []
    }
}
