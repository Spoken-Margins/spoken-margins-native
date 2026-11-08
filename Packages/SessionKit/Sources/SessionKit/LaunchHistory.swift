import Foundation

/// How long each recent launch took to reach a usable screen, and how the runs before them ended, for
/// Diagnostics (#3752).
///
/// The event log keeps only its last 300 events, so a busy session pushes out the launches of the day
/// before, and the question "was it slow to open?" had no answer in the export. This history is small,
/// kept apart from that ring and saved at each stage, so a launch that never finished is still in it after
/// the relaunch. A launch with no `usableMs` that is not the newest one is a run that ended, or was ended,
/// before the Library showed. One that never showed the root view at all (`no_ui`) is a launch iOS made with
/// no screen, such as a background refresh, or one that ended before the first screen; it is dropped before
/// a launch that showed a screen when the list is full.
///
/// A launch holds the build number, times in milliseconds since `App.init` (the kernel's process start can be
/// hours earlier when iOS prewarmed the app, so the time before `App.init` is kept apart), and the Library's item
/// count. An exit holds the `app.previous_exit` fields (counts and system codes only, see `PreviousRunExit`).
/// Nothing in it names the listener, an item or a title.
public struct LaunchHistory: Codable, Sendable, Equatable {
    public struct Launch: Codable, Sendable, Equatable {
        public var startedAt: Date
        public var build: String
        /// Process start to `App.init`: the time before the app's own code could run. Nil when it is unknown or
        /// the process was prewarmed, when the gap is idle time.
        public var preInitMs: Int?
        public var prewarmed: Bool?
        /// `App.init` to the root view's first appearance.
        public var rootAppearMs: Int?
        /// `App.init` to the Library's rows being loaded and published.
        public var libraryReadyMs: Int?
        /// `App.init` to the root view showing the loaded Library: the first usable screen.
        public var usableMs: Int?
        public var libraryItems: Int?
        /// Set when the Library could not be opened, in place of `libraryReadyMs`.
        public var libraryFailed: Bool?
    }

    public struct Exit: Codable, Sendable, Equatable {
        public var recordedAt: Date
        /// `launch` for the read at launch, `late` for a report that arrived during the run.
        public var delivery: String
        public var reason: String
        /// The event's other fields as `key=value`, sorted, cut to `maxDetailLength`.
        public var detail: String
    }

    public enum Stage: String, Sendable {
        case rootAppear, libraryReady, usable
    }

    public static let launchCapacity = 10
    public static let exitCapacity = 8
    public static let maxDetailLength = 480
    public static let noneReported = "none_reported"

    public private(set) var launches: [Launch]
    public private(set) var exits: [Exit]

    public init(launches: [Launch] = [], exits: [Exit] = []) {
        self.launches = Array(launches.suffix(Self.launchCapacity))
        self.exits = Array(exits.suffix(Self.exitCapacity))
    }

    /// Starts a launch. Later marks belong to it until the next one.
    public mutating func beginLaunch(at time: Date, build: String, preInitMs: Int? = nil, prewarmed: Bool = false) {
        launches.append(Launch(startedAt: time, build: Self.plain(build, limit: 16),
                               preInitMs: prewarmed ? nil : preInitMs, prewarmed: prewarmed ? true : nil))
        while launches.count > Self.launchCapacity {
            // Never the newest (the one starting now). A launch with no screen goes before one that had a screen.
            if let silent = launches.dropLast().firstIndex(where: { $0.rootAppearMs == nil }) {
                launches.remove(at: silent)
            } else {
                launches.removeFirst()
            }
        }
    }

    /// Marks a stage of the newest launch. A negative elapsed time (the clock moved) is dropped, a stage
    /// already marked keeps its first time, and the first usable screen can't come before the Library is ready.
    public mutating func mark(_ stage: Stage, elapsedMs: Int, libraryItems: Int? = nil, libraryFailed: Bool = false) {
        guard var launch = launches.last, elapsedMs >= 0 else { return }
        switch stage {
        case .rootAppear: launch.rootAppearMs = launch.rootAppearMs ?? elapsedMs
        case .libraryReady:
            if libraryFailed {
                launch.libraryFailed = true
            } else if launch.libraryReadyMs == nil {
                launch.libraryReadyMs = elapsedMs
                launch.libraryItems = libraryItems
            }
        case .usable:
            guard launch.libraryReadyMs != nil else { return }
            launch.usableMs = launch.usableMs ?? elapsedMs
        }
        launches[launches.count - 1] = launch
    }

    /// Keeps one `app.previous_exit` event's fields. When the list is full, a `none_reported` entry goes before
    /// any entry that names a crash, a kill or a hang, so the reports that matter outlast the empty ones.
    public mutating func recordExit(fields: [String: String], at time: Date) {
        let reason = Self.plain(fields["reason"] ?? "unknown", limit: 160)
        let skipped: Set<String> = ["source", "reason", "delivery", "newReports"]
        var detail = fields.filter { !skipped.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.plain($0.value, limit: 120))" }
            .joined(separator: ",")
        if detail.count > Self.maxDetailLength { detail = String(detail.prefix(Self.maxDetailLength)) + "..." }
        exits.append(Exit(recordedAt: time, delivery: Self.plain(fields["delivery"] ?? "launch", limit: 16),
                          reason: reason, detail: detail))
        while exits.count > Self.exitCapacity {
            if let empty = exits.firstIndex(where: { $0.reason == Self.noneReported }) {
                exits.remove(at: empty)
            } else {
                exits.removeFirst()
            }
        }
    }

    /// Newest last, for example
    /// `10-01 13:40Z b36 pre 180ms root 420ms ready 1520ms n=398 usable 1534ms | 10-01 13:52Z b36 pre 175ms root 400ms no_usable_screen`.
    /// The newest launch may still be starting, so it shows the stages it has reached.
    public var launchesLine: String {
        guard !launches.isEmpty else { return "none" }
        return launches.enumerated().map { index, launch in
            let isNewest = index == launches.count - 1
            var parts = ["\(Self.timeLabel(launch.startedAt)) b\(launch.build)"]
            if launch.prewarmed == true { parts.append("prewarmed") }
            if let value = launch.preInitMs { parts.append("pre \(value)ms") }
            if let value = launch.rootAppearMs { parts.append("root \(value)ms") }
            if let value = launch.libraryReadyMs {
                parts.append("ready \(value)ms" + (launch.libraryItems.map { " n=\($0)" } ?? ""))
            }
            if launch.libraryFailed == true { parts.append("library_failed") }
            if let value = launch.usableMs {
                parts.append("usable \(value)ms")
            } else if !isNewest {
                parts.append(launch.rootAppearMs == nil ? "no_ui" : "no_usable_screen")
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: " | ")
    }

    /// Newest last, for example `10-01 13:41Z launch crash crashes=1,crashSignal=SIGSEGV | ...`.
    public var exitsLine: String {
        guard !exits.isEmpty else { return "none" }
        return exits.map { exit in
            var text = "\(Self.timeLabel(exit.recordedAt)) \(exit.delivery) \(exit.reason)"
            if !exit.detail.isEmpty { text += " " + exit.detail }
            return text
        }
        .joined(separator: " | ")
    }

    /// Milliseconds from `start` to `now`, or nil when the start is unknown or the clock went backwards.
    public static func elapsedMs(from start: Date?, to now: Date) -> Int? {
        guard let start else { return nil }
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 0, seconds < 86_400 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    /// Plain characters only, so free text never reaches the log.
    static func plain(_ text: String, limit: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:,-=")
        let cleaned = String(text.map { allowed.contains($0) ? $0 : "?" })
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    static func timeLabel(_ time: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: time)
        func two(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(two(parts.month))-\(two(parts.day)) \(two(parts.hour)):\(two(parts.minute))Z"
    }
}
