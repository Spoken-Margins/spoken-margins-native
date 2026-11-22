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
/// count. A launch also keeps the main-thread stalls the hang probe saw in its first minute (`hangs`, #3752): how many,
/// how long in all, and when, how long and in what work the longest ones were, so a launch that took 19 s says where
/// the main thread was. An exit holds the `app.previous_exit` fields (counts and system codes only, see `PreviousRunExit`).
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
        /// `App.init` to the launch's feed refresh finishing: Following is up to date (#4388). Nil until then, and for a
        /// launch whose refresh never ran or never finished. Older builds ignore the key.
        public var followingFreshMs: Int?
        /// True when that refresh covered only Following's first screen (Low Power Mode), so the other feeds are still stale.
        public var followingFirstScreenOnly: Bool?
        public var libraryItems: Int?
        /// Set when the Library could not be opened, in place of `libraryReadyMs`.
        public var libraryFailed: Bool?
        /// Main-thread stalls of 250 ms or more that ended in the launch's first `hangWindowMs`: how many, their total
        /// milliseconds, and the longest `maxHangsPerLaunch` of them in time order. Nil when there were none, and in a
        /// history saved before this field; older builds ignore the keys.
        public var hangCount: Int?
        public var hangTotalMs: Int?
        public var hangs: [Hang]?
    }

    /// One main-thread stall: when it began (milliseconds since `App.init`), how long it lasted, the innermost work
    /// label it ended in, and where its samples fell (`label=count` pairs). Labels are fixed names written in code.
    public struct Hang: Codable, Sendable, Equatable {
        public var atMs: Int
        public var durationMs: Int
        public var operation: String
        public var samples: String?
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
        case rootAppear, libraryReady, usable, followingFresh
    }

    /// Only stalls that end this long after `App.init` belong to the launch; later ones are the session's, and the
    /// event log has them.
    public static let hangWindowMs = 60_000
    public static let maxHangsPerLaunch = 5
    public static let maxHangLabelLength = 120
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
    public mutating func mark(_ stage: Stage, elapsedMs: Int, libraryItems: Int? = nil, libraryFailed: Bool = false, firstScreenOnly: Bool = false) {
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
        case .followingFresh:
            guard launch.followingFreshMs == nil else { return }
            launch.followingFreshMs = elapsedMs
            launch.followingFirstScreenOnly = firstScreenOnly ? true : nil
        }
        launches[launches.count - 1] = launch
    }

    /// Keeps a main-thread stall that just ended, as part of the newest launch (#3752). `elapsedMs` is the time since
    /// `App.init` at the moment the stall ended, so it began `durationMs` earlier. A stall that began after
    /// `hangWindowMs` (a long one that began inside it still counts, and may end after it), one with a negative time or
    /// no length, or one with no launch to belong to is dropped. Every stall in the window is counted; only the longest
    /// `maxHangsPerLaunch` keep their details, shown in time order. Returns whether the stall was taken, so a caller
    /// need not save or publish for one that was not.
    @discardableResult
    public mutating func noteHang(elapsedMs: Int, durationMs: Int, operation: String, samples: String? = nil) -> Bool {
        guard var launch = launches.last, elapsedMs >= 0, durationMs > 0,
              elapsedMs - durationMs <= Self.hangWindowMs else { return false }
        let label = operation.isEmpty ? "none" : operation
        let samplesText = (samples ?? "").isEmpty ? nil : Self.plainSamples(samples ?? "")
        launch.hangCount = (launch.hangCount ?? 0) + 1
        launch.hangTotalMs = (launch.hangTotalMs ?? 0) + durationMs
        var stalls = launch.hangs ?? []
        stalls.append(Hang(atMs: max(0, elapsedMs - durationMs), durationMs: durationMs,
                         operation: Self.plainOperation(label), samples: samplesText))
        if stalls.count > Self.maxHangsPerLaunch {
            // The shortest goes; of equal lengths, the one that began later.
            if let shortest = stalls.indices.min(by: { (stalls[$0].durationMs, -$0) < (stalls[$1].durationMs, -$1) }) {
                stalls.remove(at: shortest)
            }
        }
        launch.hangs = stalls.sorted { $0.atMs < $1.atMs }
        launches[launches.count - 1] = launch
        return true
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
            if let value = launch.followingFreshMs {
                parts.append("following_fresh \(value)ms" + (launch.followingFirstScreenOnly == true ? " first_screen_only" : ""))
            }
            if let count = launch.hangCount, count > 0 {
                parts.append("hangs \(count) total \(launch.hangTotalMs ?? 0)ms")
                let details = (launch.hangs ?? []).map { hang -> String in
                    var text = "\(hang.durationMs)ms@\(hang.atMs) \(hang.operation)"
                    if let samples = hang.samples { text += " (\(samples))" }
                    return text
                }
                if !details.isEmpty { parts.append("[" + details.joined(separator: "; ") + "]") }
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

    private static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:,-=>;")

    private static func labelText(_ text: String) -> String {
        String(text.map { labelCharacters.contains($0) ? $0 : "?" })
    }

    /// For an operation label (`a>b` is a stack, outermost first, innermost last): fixed names written in code. When it
    /// is too long the outer end goes, because the innermost label is the one that names the work.
    static func plainOperation(_ text: String) -> String {
        let cleaned = labelText(text)
        return cleaned.count > maxHangLabelLength ? ">" + String(cleaned.suffix(maxHangLabelLength - 1)) : cleaned
    }

    /// For a `label=count;label=count` list: whole pairs only, so a cut never leaves a `label=` with no count.
    static func plainSamples(_ text: String) -> String {
        let cleaned = labelText(text)
        guard cleaned.count > maxHangLabelLength else { return cleaned }
        var pairs: [Substring] = []
        var length = 0
        for pair in cleaned.split(separator: ";") {
            let added = pair.count + (pairs.isEmpty ? 0 : 1)
            if length + added > maxHangLabelLength { break }
            pairs.append(pair)
            length += added
        }
        return pairs.joined(separator: ";")
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
