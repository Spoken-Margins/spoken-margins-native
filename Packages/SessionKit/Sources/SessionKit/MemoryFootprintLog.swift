import Foundation

/// The app's memory use over time, for Diagnostics (#122).
///
/// iOS ends an app that uses too much memory without a crash report, so a kill looks like any other
/// relaunch. The app samples its physical footprint when an item starts playing, when playback moves to
/// another item, every minute of playback and on each memory warning, and keeps the last 20 samples across
/// launches. A `launch` sample marks each relaunch, so samples that climb and then stop at a `launch` point
/// to a kill. A sample holds only the event, the media type and sizes: never a title, an id or text.
public struct MemoryFootprintLog: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable {
        case launch
        /// The first item played since launch.
        case itemStart = "item_start"
        /// Playback moved to a different item.
        case itemSwitch = "item_switch"
        /// A minute of playback passed since the last sample.
        case playback
        case memoryWarning = "memory_warning"
    }

    public struct Sample: Codable, Sendable, Equatable {
        public let time: Date
        public let event: Event
        public let mediaType: String
        public let footprintBytes: UInt64
        /// What iOS would still let the app allocate (`os_proc_available_memory`), when known.
        public let availableBytes: UInt64?
    }

    public static let capacity = 20
    public static let playbackInterval: TimeInterval = 60

    public private(set) var samples: [Sample]
    /// The item the last start or switch sample was for. Not saved: after a relaunch the first item is a start.
    private var lastPlayedItemId: String?

    private enum CodingKeys: String, CodingKey { case samples }

    public init(samples: [Sample] = []) {
        self.samples = Array(samples.suffix(Self.capacity))
    }

    public mutating func record(
        _ event: Event,
        mediaType: String?,
        footprintBytes: UInt64,
        availableBytes: UInt64?,
        at time: Date
    ) {
        if event == .launch { lastPlayedItemId = nil }
        samples.append(Sample(
            time: time,
            event: event,
            mediaType: Self.mediaTypeLabel(mediaType),
            footprintBytes: footprintBytes,
            availableBytes: availableBytes
        ))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The sample a playback change calls for: `item_start` for the first item played since launch,
    /// `item_switch` when a different item starts playing, nothing for pausing or resuming the same item.
    public mutating func eventForPlayback(itemId: String?, isPlaying: Bool) -> Event? {
        guard isPlaying, let itemId, itemId != lastPlayedItemId else { return nil }
        defer { lastPlayedItemId = itemId }
        return lastPlayedItemId == nil ? .itemStart : .itemSwitch
    }

    /// A playback sample is due a minute after the last sample of any kind, or when the clock went backwards.
    public func playbackSampleIsDue(at time: Date) -> Bool {
        guard let last = samples.last?.time else { return true }
        return time < last || time.timeIntervalSince(last) >= Self.playbackInterval
    }

    /// Newest last, for example `10-01 13:40:02Z item_switch text 412MB free 1630MB | ...`.
    public var diagnosticsLine: String {
        samples.map { sample in
            var entry = "\(Self.timeLabel(sample.time)) \(sample.event.rawValue) \(sample.mediaType) \(Self.megabytes(sample.footprintBytes))MB"
            if let available = sample.availableBytes {
                entry += " free \(Self.megabytes(available))MB"
            }
            return entry
        }
        .joined(separator: " | ")
    }

    /// Media types are short machine labels such as `text` or `podcast`; anything else is shown as `other`,
    /// so a stray title can never reach Diagnostics.
    static func mediaTypeLabel(_ mediaType: String?) -> String {
        guard let mediaType, !mediaType.isEmpty else { return "none" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        guard mediaType.count <= 24, mediaType.allSatisfy({ allowed.contains($0) }) else { return "other" }
        return mediaType
    }

    static func megabytes(_ bytes: UInt64) -> UInt64 {
        (bytes + 524_288) / 1_048_576
    }

    static func timeLabel(_ time: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: time)
        func two(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(two(parts.month))-\(two(parts.day)) \(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))Z"
    }
}

/// How often iOS ended the app for using too much memory, from the latest MetricKit app-exit report (#122).
///
/// MetricKit delivers one report per day, after the day ends, so counts lag a day behind. Read from the
/// report's JSON form (`MXMetricPayload.jsonRepresentation()`), which is also what a recorded report is.
/// A count the report leaves out reads "not reported", so a missing field is never shown as zero.
public struct MemoryExitCounts: Sendable, Equatable {
    public let foregroundMemoryLimit: Int?
    public let backgroundMemoryLimit: Int?
    /// Background exits because the whole system ran short of memory, not because of the app's own use.
    public let backgroundMemoryPressure: Int?
    /// The report's period, as `yyyy-MM-dd`, when the report gives one.
    public let periodStart: String?
    public let periodEnd: String?

    public init(
        foregroundMemoryLimit: Int?,
        backgroundMemoryLimit: Int?,
        backgroundMemoryPressure: Int?,
        periodStart: String?,
        periodEnd: String?
    ) {
        self.foregroundMemoryLimit = foregroundMemoryLimit
        self.backgroundMemoryLimit = backgroundMemoryLimit
        self.backgroundMemoryPressure = backgroundMemoryPressure
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }

    /// Nil when the data isn't a report or carries no app-exit section.
    public init?(metricPayloadJSON data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exits = root["applicationExitMetrics"] as? [String: Any] else { return nil }
        let foreground = exits["foregroundExitData"] as? [String: Any]
        let background = exits["backgroundExitData"] as? [String: Any]
        self.init(
            foregroundMemoryLimit: Self.count(foreground?["cumulativeMemoryResourceLimitExitCount"]),
            backgroundMemoryLimit: Self.count(background?["cumulativeMemoryResourceLimitExitCount"]),
            backgroundMemoryPressure: Self.count(background?["cumulativeMemoryPressureExitCount"]),
            periodStart: Self.day(root["timeStampBegin"]),
            periodEnd: Self.day(root["timeStampEnd"])
        )
    }

    /// For example `foreground 2 · background 0 · background system pressure 1 · 2026-09-30 to 2026-10-01`.
    public var diagnosticsLine: String {
        var parts = [
            "foreground \(Self.label(foregroundMemoryLimit))",
            "background \(Self.label(backgroundMemoryLimit))",
            "background system pressure \(Self.label(backgroundMemoryPressure))",
        ]
        if let periodStart, let periodEnd {
            parts.append("\(periodStart) to \(periodEnd)")
        }
        return parts.joined(separator: " · ")
    }

    private static func label(_ count: Int?) -> String {
        count.map(String.init) ?? "not reported"
    }

    private static func count(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func day(_ value: Any?) -> String? {
        guard let text = value as? String, text.count >= 10 else { return nil }
        let day = String(text.prefix(10))
        let pattern = day.map { $0.isNumber ? "9" : $0 }
        return String(pattern) == "9999-99-99" ? day : nil
    }
}
