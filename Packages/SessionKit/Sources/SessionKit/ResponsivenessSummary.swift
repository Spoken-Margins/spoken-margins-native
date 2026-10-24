import Foundation

/// One line at the top of an export's story about freezes and slow taps (#2096): how many main-thread hangs the
/// event log holds, the longest, and how long taps took to show. It is read from `playbackEvents` (`main.hang`,
/// `transport.state` and `session.end`, all from #2099), so it holds only counts and milliseconds. The daily
/// phone-plan job and the Test Desk read the `budget=` word; `broken(...)` names the budgets that failed.
public struct ResponsivenessSummary: Equatable, Sendable {
    /// The always-on probe records a hang from this lateness, and the budget allows none over it.
    public static let hangBudgetMs = 250
    /// The slowest tap-to-state time that still feels immediate, at the 95th percentile.
    public static let tapToStateBudgetMs = 100
    /// The pill's X to the session ending (#2097).
    public static let closeBudgetMs = 300

    public let hangCount: Int
    /// Hangs the app saw but left out of the log, so a stall storm doesn't push out the tap history.
    public let hangsSkipped: Int
    public let longestHangMs: Int
    public let hangsOverBudget: Int
    public let tapCount: Int
    public let tapToStateP95Ms: Int?
    public let closeCount: Int
    public let longestCloseMs: Int?

    /// The budgets that failed, in the order `text` names them: `hang`, `tap`, `close`.
    public var brokenBudgets: [String] {
        var broken: [String] = []
        if hangsOverBudget > 0 || hangsSkipped > 0 { broken.append("hang") }
        if let p95 = tapToStateP95Ms, p95 > Self.tapToStateBudgetMs { broken.append("tap") }
        if let longest = longestCloseMs, longest > Self.closeBudgetMs { broken.append("close") }
        return broken
    }

    public var text: String {
        let verdict = brokenBudgets.isEmpty ? "ok" : "broken(\(brokenBudgets.joined(separator: ",")))"
        return [
            "hangs=\(hangCount)",
            "skipped=\(hangsSkipped)",
            "longestHangMs=\(longestHangMs)",
            "hangsOver\(Self.hangBudgetMs)Ms=\(hangsOverBudget)",
            "taps=\(tapCount)",
            "tapToStateP95Ms=\(tapToStateP95Ms.map(String.init) ?? "none")",
            "closes=\(closeCount)",
            "longestCloseMs=\(longestCloseMs.map(String.init) ?? "none")",
            "budget=\(verdict)",
        ].joined(separator: " ")
    }

    /// Reads the summary from the `playbackEvents` export text (`{"events": [{"kind": ..., "fields": {...}}]}`).
    /// Text that isn't that shape reads as an empty log.
    public init(playbackEventsJSON: String?) {
        let events = Self.events(in: playbackEventsJSON)
        var hangs: [Int] = []
        var skipped = 0
        var tapTimes: [Int] = []
        var closeTimes: [Int] = []
        for event in events {
            switch event.kind {
            case "main.hang":
                if let ms = event.number("durationMs") { hangs.append(ms) }
                skipped += event.number("skipped") ?? 0
            case TapToStateTracker.eventKind:
                if let ms = event.number("tapToStateMs") { tapTimes.append(ms) }
            case "session.end":
                if let ms = event.number("tapToEndMs") { closeTimes.append(ms) }
            default:
                break
            }
        }
        hangCount = hangs.count
        hangsSkipped = skipped
        longestHangMs = hangs.max() ?? 0
        hangsOverBudget = hangs.filter { $0 > Self.hangBudgetMs }.count
        tapCount = tapTimes.count
        tapToStateP95Ms = Self.percentile95(tapTimes)
        closeCount = closeTimes.count
        longestCloseMs = closeTimes.max()
    }

    /// Nearest rank: the smallest value that at least 95% of the readings do not exceed.
    static func percentile95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
    }

    private struct Event {
        let kind: String
        let fields: [String: Any]

        func number(_ key: String) -> Int? {
            switch fields[key] {
            case let text as String: return Int(text)
            case let number as NSNumber: return number.intValue
            default: return nil
            }
        }
    }

    private static func events(in json: String?) -> [Event] {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let raw = object["events"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let kind = entry["kind"] as? String else { return nil }
            return Event(kind: kind, fields: entry["fields"] as? [String: Any] ?? [:])
        }
    }
}
