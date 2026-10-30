import BatteryLensShared
import Foundation

/// Every change in a battery's level or charging state, for the history chart and the
/// time-remaining estimate (phase 7). Recorded from phase 2 so there's data by then.
///
/// One JSON line per change in Application Support; samples older than 90 days are
/// dropped at launch.
public final class ChargeHistory {
    public struct Sample: Codable, Hashable, Sendable {
        public var device: String
        public var part: BatteryPart?
        public var percent: Int
        public var isCharging: Bool
        public var date: Date
    }

    public static let retention: TimeInterval = 90 * 24 * 3600

    public private(set) var samples: [Sample] = []
    private var last: [String: Sample] = [:]
    private let fileURL: URL?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// `fileURL` nil keeps the history in memory (tests).
    public init(fileURL: URL? = ChargeHistory.defaultURL, now: Date = Date()) {
        self.fileURL = fileURL
        load(now: now)
    }

    public static var defaultURL: URL? {
        DeviceStore.defaultURL?.deletingLastPathComponent().appendingPathComponent("history.jsonl")
    }

    /// Records the levels of connected devices that changed since their last sample.
    public func record(_ devices: [DeviceBattery]) {
        var added: [Sample] = []
        for device in devices where device.isConnected {
            for level in device.levels {
                let key = Self.key(device.id, level.part)
                if let previous = last[key], previous.percent == level.percent, previous.isCharging == level.isCharging { continue }
                let sample = Sample(device: device.id, part: level.part, percent: level.percent,
                                    isCharging: level.isCharging, date: level.date)
                last[key] = sample
                added.append(sample)
            }
        }
        guard !added.isEmpty else { return }
        samples += added
        append(added)
    }

    public func samples(for device: String, part: BatteryPart?) -> [Sample] {
        samples.filter { $0.device == device && $0.part == part }
    }

    /// Every battery of a device: earbuds and their case too.
    public func samples(for device: String) -> [Sample] {
        samples.filter { $0.device == device }
    }

    private static func key(_ device: String, _ part: BatteryPart?) -> String { device + "/" + (part?.rawValue ?? "main") }

    private func load(now: Date) {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = text.split(separator: "\n").compactMap { try? decoder.decode(Sample.self, from: Data($0.utf8)) }
        samples = all.filter { now.timeIntervalSince($0.date) <= Self.retention }
        for sample in samples { last[Self.key(sample.device, sample.part)] = sample }
        if samples.count != all.count { rewrite() }
    }

    private func line(_ sample: Sample) -> String? {
        (try? encoder.encode(sample)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func append(_ new: [Sample]) {
        guard let fileURL else { return }
        let text = new.compactMap(line).map { $0 + "\n" }.joined()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try handle.close()
            } else {
                try Data(text.utf8).write(to: fileURL)
            }
        } catch {
            SharedContainer.log("history: couldn't save: \(error.localizedDescription)")
        }
    }

    private func rewrite() {
        guard let fileURL else { return }
        let text = samples.compactMap(line).map { $0 + "\n" }.joined()
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }
}
