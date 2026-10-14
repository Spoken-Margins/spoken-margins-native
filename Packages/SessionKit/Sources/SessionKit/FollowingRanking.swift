import Foundation

/// What the listener has done with one followed source, summed from the I4 engagement log
/// (#483). The ranking uses five features of it, as `research/D3/rank.py` does (#484).
public struct FollowingSourceSignals: Equatable, Sendable {
    public var listenedSeconds: Double
    /// Summed durations of the source's items seen in the log whose duration is known.
    public var knownDurationSeconds: Double
    public var itemsSeen: Int
    public var itemsFinished: Int
    public var itemsDismissed: Int
    public var marginCount: Int
    public var shareCount: Int

    public init(
        listenedSeconds: Double = 0,
        knownDurationSeconds: Double = 0,
        itemsSeen: Int = 0,
        itemsFinished: Int = 0,
        itemsDismissed: Int = 0,
        marginCount: Int = 0,
        shareCount: Int = 0
    ) {
        self.listenedSeconds = listenedSeconds
        self.knownDurationSeconds = knownDurationSeconds
        self.itemsSeen = itemsSeen
        self.itemsFinished = itemsFinished
        self.itemsDismissed = itemsDismissed
        self.marginCount = marginCount
        self.shareCount = shareCount
    }

    public var listenedShare: Double {
        knownDurationSeconds > 0 ? min(1, listenedSeconds / knownDurationSeconds) : 0
    }

    public var finishRate: Double { Double(itemsFinished) / Double(max(1, itemsSeen)) }
    public var dismissRate: Double { Double(itemsDismissed) / Double(max(1, itemsSeen)) }

    /// True when no feature has anything to say, so only recency ranks the source.
    public var isEmpty: Bool {
        listenedShare == 0 && finishRate == 0 && dismissRate == 0 && marginCount == 0 && shareCount == 0
    }
}

/// Reads per-source signals from an I4 JSON Lines log, keyed by the log's `source.id` (the
/// followed source's SourceIdentity id, not its FeedSubscription id). Tolerant, unlike the research
/// evaluator: a line that isn't a JSON object, an unknown event, or a row without a source
/// is skipped, so a newer or damaged log still ranks with whatever it can read.
public enum FollowingSignalLog {
    /// A missing or unreadable file means no signals, which ranks newest-first.
    public static func signals(contentsOf url: URL) -> [String: FollowingSourceSignals] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return signals(fromJSONLines: data)
    }

    public static func signals(fromJSONLines data: Data) -> [String: FollowingSourceSignals] {
        struct Tally {
            var listened = 0.0
            var seen: Set<String> = []
            var finished: Set<String> = []
            var dismissed: Set<String> = []
            var margins = 0
            var shares = 0
        }
        var tallies: [String: Tally] = [:]
        var durations: [String: Double] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let event = row["event"] as? String,
                  let sourceID = (row["source"] as? [String: Any])?["id"] as? String,
                  let item = row["item"] as? [String: Any],
                  let itemID = item["id"] as? String else { continue }
            var tally = tallies[sourceID] ?? Tally()
            tally.seen.insert(itemID)
            // Often null when an item is published and known once it plays, so keep the largest seen.
            let duration = (item["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
            durations[itemID] = max(durations[itemID] ?? 0, duration)
            switch event {
            case "listened":
                if let seconds = (row["seconds"] as? NSNumber)?.doubleValue, seconds > 0 { tally.listened += seconds }
            case "finish": tally.finished.insert(itemID)
            case "margin": tally.margins += 1
            case "share": tally.shares += 1
            case "dismiss": tally.dismissed.insert(itemID)
            default: break
            }
            tallies[sourceID] = tally
        }
        return tallies.mapValues { tally in
            FollowingSourceSignals(
                listenedSeconds: tally.listened,
                knownDurationSeconds: tally.seen.reduce(0) { $0 + max(0, durations[$1] ?? 0) },
                itemsSeen: tally.seen.count,
                itemsFinished: tally.finished.count,
                itemsDismissed: tally.dismissed.count,
                marginCount: tally.margins,
                shareCount: tally.shares
            )
        }
    }
}

/// The score's weights: `research/D3/policy.json` (ranking-policy.draft-1). The owner's
/// D3 M2 evaluation may change them.
public struct FollowingRankingPolicy: Equatable, Sendable {
    public var recencyHalfLifeDays: Double
    public var listenedShare: Double
    public var finishRate: Double
    public var marginCount: Double
    public var shareCount: Double
    public var dismissRate: Double

    public static let d3Draft = FollowingRankingPolicy(
        recencyHalfLifeDays: 10, listenedShare: 1.8, finishRate: 2.2,
        marginCount: 0.35, shareCount: 0.55, dismissRate: -2.4
    )

    public init(recencyHalfLifeDays: Double, listenedShare: Double, finishRate: Double, marginCount: Double, shareCount: Double, dismissRate: Double) {
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.listenedShare = listenedShare
        self.finishRate = finishRate
        self.marginCount = marginCount
        self.shareCount = shareCount
        self.dismissRate = dismissRate
    }
}

/// Pin and "Less of this show", per followed source. Kept in a small JSON file next to the
/// I4 log, not in the database, so Build 29's database is untouched (#484).
public struct FollowingPreferences: Codable, Equatable, Sendable {
    public enum Mark: String, Codable, Sendable {
        case pinned
        case less
    }

    public static let currentSchemaVersion = "following-preferences.v1"
    public static let fileName = "following-preferences.json"

    public private(set) var marks: [String: Mark]

    public init(marks: [String: Mark] = [:]) {
        self.marks = marks
    }

    public func mark(for sourceID: String) -> Mark? { marks[sourceID] }

    /// A source has at most one mark: pinning clears "less", and the other way round.
    /// `nil` clears it, which is how both are undone.
    public mutating func setMark(_ mark: Mark?, for sourceID: String) {
        marks[sourceID] = mark
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pinned
        case less
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var marks: [String: Mark] = [:]
        for id in try container.decodeIfPresent([String].self, forKey: .less) ?? [] { marks[id] = .less }
        for id in try container.decodeIfPresent([String].self, forKey: .pinned) ?? [] { marks[id] = .pinned }
        self.marks = marks
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(marks.filter { $0.value == .pinned }.keys.sorted(), forKey: .pinned)
        try container.encode(marks.filter { $0.value == .less }.keys.sorted(), forKey: .less)
    }

    /// A missing or unreadable file means nothing is marked.
    public static func load(from url: URL) -> FollowingPreferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(FollowingPreferences.self, from: data) else { return FollowingPreferences() }
        return preferences
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Why an item sits where it does under Top, in one line the row can show.
public enum FollowingRankReason: Equatable, Sendable {
    case pinned
    case lessOfThisShow
    /// Nothing recorded for the source yet, so only its date counts.
    case newest
    case listensToMuch
    case oftenFinishes
    case margins(Int)
    case shares(Int)
    case oftenDismisses

    public var text: String {
        switch self {
        case .pinned: "You pinned this show"
        case .lessOfThisShow: "You asked for less of this show"
        case .newest: "Newest first: nothing recorded for this show yet"
        case .listensToMuch: "You listen to much of this show"
        case .oftenFinishes: "You often finish this show"
        case .margins(let count): count == 1 ? "You've made 1 Margin on this show" : "You've made \(count) Margins on this show"
        case .shares(let count): count == 1 ? "You've shared 1 item from this show" : "You've shared \(count) items from this show"
        case .oftenDismisses: "You often dismiss this show"
        }
    }
}

/// One new item to rank. `sourceID` is its followed source's SourceIdentity id (the I4 log's
/// `source.id`), or nil for an item with no source, such as a Quick Folder file.
public struct FollowingRankInput: Equatable, Sendable {
    public var id: String
    public var sourceID: String?
    public var publishedAt: Date?

    public init(id: String, sourceID: String?, publishedAt: Date?) {
        self.id = id
        self.sourceID = sourceID
        self.publishedAt = publishedAt
    }
}

public struct FollowingRankedItem: Equatable, Sendable {
    public var id: String
    public var score: Double
    public var reason: FollowingRankReason
}

/// Following's "Top" order (#484): a port of `research/D3/rank.py`'s transparent score.
/// The score is recency (halving every `recencyHalfLifeDays`) plus the weighted source
/// features; the reason names the feature that moved it most. With no signals the order is
/// newest-first. A pinned source's items always come first and a "less of this" source's
/// items come after every unmarked one; within each group the score decides.
public enum FollowingRanker {
    public static func rank(
        _ items: [FollowingRankInput],
        asOf now: Date,
        signals: [String: FollowingSourceSignals],
        preferences: FollowingPreferences = FollowingPreferences(),
        policy: FollowingRankingPolicy = .d3Draft
    ) -> [FollowingRankedItem] {
        struct Scored {
            var ranked: FollowingRankedItem
            var group: Int
            var date: Date
        }
        let scored = items.map { item -> Scored in
            let date = item.publishedAt ?? .distantPast
            let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
            let recency = exp(-log(2) * ageDays / policy.recencyHalfLifeDays)
            let source = item.sourceID.flatMap { signals[$0] } ?? FollowingSourceSignals()
            let contributions: [(Double, FollowingRankReason)] = [
                (policy.listenedShare * source.listenedShare, .listensToMuch),
                (policy.finishRate * source.finishRate, .oftenFinishes),
                (policy.marginCount * Double(source.marginCount), .margins(source.marginCount)),
                (policy.shareCount * Double(source.shareCount), .shares(source.shareCount)),
                (policy.dismissRate * source.dismissRate, .oftenDismisses),
            ]
            let score = recency + contributions.reduce(0) { $0 + $1.0 }
            var reason = FollowingRankReason.newest
            if !source.isEmpty, let top = contributions.max(by: { abs($0.0) < abs($1.0) }) { reason = top.1 }
            var group = 1
            switch item.sourceID.flatMap(preferences.mark(for:)) {
            case .pinned?: group = 0; reason = .pinned
            case .less?: group = 2; reason = .lessOfThisShow
            case nil: break
            }
            return Scored(ranked: FollowingRankedItem(id: item.id, score: score, reason: reason), group: group, date: date)
        }
        return scored.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.ranked.score != b.ranked.score { return a.ranked.score > b.ranked.score }
            if a.date != b.date { return a.date > b.date }
            return a.ranked.id < b.ranked.id
        }.map(\.ranked)
    }
}
