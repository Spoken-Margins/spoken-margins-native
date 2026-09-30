import Foundation
import XCTest
@testable import SessionKit

/// #484: Following's "Top" order, a port of research/D3/rank.py, with Pin and "Less of this show".
final class FollowingRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// The inbox's current order (Gate1AppModel.quickAddCandidates): date, newest first, then id.
    private func newestFirst(_ items: [FollowingRankInput]) -> [String] {
        items.sorted {
            let a = $0.publishedAt ?? .distantPast, b = $1.publishedAt ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }.map(\.id)
    }

    private var mixedInbox: [FollowingRankInput] {
        [
            FollowingRankInput(id: "a", sourceID: "s1", publishedAt: daysAgo(3)),
            FollowingRankInput(id: "b", sourceID: "s2", publishedAt: daysAgo(0.5)),
            FollowingRankInput(id: "c", sourceID: "s1", publishedAt: daysAgo(40)),
            FollowingRankInput(id: "d", sourceID: "s3", publishedAt: daysAgo(400)),
            FollowingRankInput(id: "e", sourceID: "s3", publishedAt: daysAgo(900)),
            FollowingRankInput(id: "f", sourceID: nil, publishedAt: daysAgo(3)),  // Quick Folder file, same date as a
            FollowingRankInput(id: "g", sourceID: "s2", publishedAt: nil),
            FollowingRankInput(id: "h", sourceID: "s2", publishedAt: now.addingTimeInterval(3_600)),  // future-dated
            FollowingRankInput(id: "i", sourceID: "s4", publishedAt: now.addingTimeInterval(7_200)),
        ]
    }

    func testWithNoSignalsTheOrderIsNewestFirst() {
        let ranked = FollowingRanker.rank(mixedInbox, asOf: now, signals: [:])
        XCTAssertEqual(ranked.map(\.id), newestFirst(mixedInbox))
        XCTAssertTrue(ranked.allSatisfy { $0.reason == .newest })
        // Sources present in the log with nothing to say rank the same way.
        let silent = ["s1": FollowingSourceSignals(itemsSeen: 4), "s2": FollowingSourceSignals(knownDurationSeconds: 0, itemsSeen: 1)]
        XCTAssertEqual(FollowingRanker.rank(mixedInbox, asOf: now, signals: silent).map(\.id), newestFirst(mixedInbox))
    }

    func testASourceWithManyMarginsOutranksASilentOneOfTheSameAge() {
        let items = [
            FollowingRankInput(id: "silent", sourceID: "quiet", publishedAt: daysAgo(2)),
            FollowingRankInput(id: "loved", sourceID: "loved", publishedAt: daysAgo(2)),
        ]
        let signals = ["loved": FollowingSourceSignals(itemsSeen: 5, marginCount: 12)]
        let ranked = FollowingRanker.rank(items, asOf: now, signals: signals)
        XCTAssertEqual(ranked.map(\.id), ["loved", "silent"])
        XCTAssertEqual(ranked[0].reason, .margins(12))
        XCTAssertEqual(ranked[0].reason.text, "You've made 12 Margins on this show")
        XCTAssertEqual(ranked[1].reason, .newest)
        // Even a much newer silent item doesn't beat twelve Margins.
        let newer = FollowingRanker.rank(items + [FollowingRankInput(id: "fresh", sourceID: "quiet", publishedAt: now)], asOf: now, signals: signals)
        XCTAssertEqual(newer.first?.id, "loved")
    }

    func testAPinnedSourceIsAlwaysFirst() {
        var preferences = FollowingPreferences()
        preferences.setMark(.pinned, for: "s3")
        let signals = ["s1": FollowingSourceSignals(itemsSeen: 2, itemsFinished: 2, marginCount: 30, shareCount: 9)]
        let ranked = FollowingRanker.rank(mixedInbox, asOf: now, signals: signals, preferences: preferences)
        XCTAssertEqual(Array(ranked.map(\.id).prefix(2)), ["d", "e"], "the pinned show's items, newest of them first")
        XCTAssertEqual(ranked[0].reason, .pinned)
        XCTAssertEqual(ranked[0].reason.text, "You pinned this show")
    }

    func testLessOfThisPushesASourceBelowUnmarkedOnes() {
        var preferences = FollowingPreferences()
        preferences.setMark(.less, for: "s1")
        let signals = ["s1": FollowingSourceSignals(itemsSeen: 2, itemsFinished: 2, marginCount: 30)]
        let ranked = FollowingRanker.rank(mixedInbox, asOf: now, signals: signals, preferences: preferences)
        XCTAssertEqual(Array(ranked.map(\.id).suffix(2)), ["a", "c"], "below even 900-day-old and undated items")
        XCTAssertEqual(ranked.last?.reason, .lessOfThisShow)
        let unmarked = ranked.dropLast(2).map(\.id)
        XCTAssertEqual(unmarked, newestFirst(mixedInbox.filter { $0.sourceID != "s1" }))
    }

    func testMarksAreReversibleAndExclusive() {
        var preferences = FollowingPreferences()
        preferences.setMark(.pinned, for: "s1")
        preferences.setMark(.less, for: "s1")
        XCTAssertEqual(preferences.mark(for: "s1"), .less, "less replaces pin")
        preferences.setMark(nil, for: "s1")
        XCTAssertNil(preferences.mark(for: "s1"))
        XCTAssertEqual(FollowingRanker.rank(mixedInbox, asOf: now, signals: [:], preferences: preferences).map(\.id), newestFirst(mixedInbox))
    }

    func testTheReasonIsTheLargestContribution() {
        func reason(_ signals: FollowingSourceSignals) -> FollowingRankReason? {
            FollowingRanker.rank([FollowingRankInput(id: "x", sourceID: "s", publishedAt: now)], asOf: now, signals: ["s": signals]).first?.reason
        }
        XCTAssertEqual(reason(FollowingSourceSignals(listenedSeconds: 3_000, knownDurationSeconds: 3_600, itemsSeen: 1)), .listensToMuch)
        XCTAssertEqual(reason(FollowingSourceSignals(itemsSeen: 4, itemsFinished: 3, marginCount: 1)), .oftenFinishes)
        XCTAssertEqual(reason(FollowingSourceSignals(itemsSeen: 1, shareCount: 1)), .shares(1))
        XCTAssertEqual(FollowingRankReason.shares(1).text, "You've shared 1 item from this show")
        XCTAssertEqual(FollowingRankReason.margins(1).text, "You've made 1 Margin on this show")
        XCTAssertEqual(reason(FollowingSourceSignals(itemsSeen: 4, itemsDismissed: 4)), .oftenDismisses)
    }

    func testOftenDismissedSourcesSinkBelowSilentOnes() {
        let items = [
            FollowingRankInput(id: "dismissed", sourceID: "d", publishedAt: now),
            FollowingRankInput(id: "silent", sourceID: "q", publishedAt: daysAgo(30)),
        ]
        let ranked = FollowingRanker.rank(items, asOf: now, signals: ["d": FollowingSourceSignals(itemsSeen: 5, itemsDismissed: 4)])
        XCTAssertEqual(ranked.map(\.id), ["silent", "dismissed"])
    }

    /// The score matches rank.py's on its own numbers: recency 2^(-age/10) plus weighted features.
    func testScoreMatchesTheResearchPolicy() {
        let signals = FollowingSourceSignals(listenedSeconds: 900, knownDurationSeconds: 1_800, itemsSeen: 4,
                                             itemsFinished: 1, itemsDismissed: 1, marginCount: 2, shareCount: 1)
        let ranked = FollowingRanker.rank([FollowingRankInput(id: "x", sourceID: "s", publishedAt: daysAgo(10))], asOf: now, signals: ["s": signals])
        let features: [Double] = [1.8 * 0.5, 2.2 * 0.25, 0.35 * 2, 0.55 * 1, -2.4 * 0.25]
        let expected: Double = 0.5 + features.reduce(0, +)
        XCTAssertEqual(ranked[0].score, expected, accuracy: 1e-9)
    }

    func testTheLogIsReadAsTheResearchEvaluatorReadsIt() throws {
        let log = """
        {"schema_version":"i4-engagement.draft-1","event":"item_published","at":"2026-09-01T08:00:00Z","source":{"id":"s1","title":"Systems Weekly"},"item":{"id":"i1","title":"Queues","published_at":"2026-09-01T08:00:00Z","duration_seconds":900}}
        {"schema_version":"i4-engagement.draft-1","event":"listened","at":"2026-09-02T08:00:00Z","source":{"id":"s1"},"item":{"id":"i1","duration_seconds":900},"seconds":300}
        {"schema_version":"i4-engagement.draft-1","event":"listened","at":"2026-09-02T09:00:00Z","source":{"id":"s1"},"item":{"id":"i1","duration_seconds":900},"seconds":150.5}
        {"schema_version":"i4-engagement.draft-1","event":"margin","at":"2026-09-02T09:10:00Z","source":{"id":"s1"},"item":{"id":"i1"},"margin_kind":"spoken","length":12,"length_unit":"seconds"}
        {"schema_version":"i4-engagement.draft-1","event":"margin","at":"2026-09-02T09:11:00Z","source":{"id":"s1"},"item":{"id":"i1"},"margin_kind":"written","length":40,"length_unit":"characters"}
        {"schema_version":"i4-engagement.draft-1","event":"finish","at":"2026-09-02T09:20:00Z","source":{"id":"s1"},"item":{"id":"i1"}}
        {"schema_version":"i4-engagement.draft-1","event":"finish","at":"2026-09-02T09:21:00Z","source":{"id":"s1"},"item":{"id":"i1"}}
        {"schema_version":"i4-engagement.draft-1","event":"share","at":"2026-09-03T09:00:00Z","source":{"id":"s1"},"item":{"id":"i2","duration_seconds":null}}
        {"schema_version":"i4-engagement.draft-1","event":"dismiss","at":"2026-09-03T09:00:00Z","source":{"id":"s2"},"item":{"id":"i3","duration_seconds":600}}
        {"schema_version":"i4-engagement.draft-1","event":"packet_import","at":"2026-09-03T10:00:00Z","source":{"id":"s2"},"item":null,"packet_id":"p","from_other":true,"margin_count":1}
        {"schema_version":"i4-engagement.draft-2","event":"a_future_event","at":"2026-09-03T11:00:00Z","source":{"id":"s2"},"item":{"id":"i4"}}
        not json at all
        [1, 2, 3]

        """
        let signals = FollowingSignalLog.signals(fromJSONLines: Data(log.utf8))
        let s1 = try XCTUnwrap(signals["s1"])
        XCTAssertEqual(s1.listenedSeconds, 450.5, accuracy: 1e-9)
        XCTAssertEqual(s1.knownDurationSeconds, 900, "an item with an unknown duration adds nothing")
        XCTAssertEqual(s1.itemsSeen, 2)
        XCTAssertEqual(s1.itemsFinished, 1, "finishing the same item twice counts once")
        XCTAssertEqual(s1.marginCount, 2)
        XCTAssertEqual(s1.shareCount, 1)
        XCTAssertEqual(s1.listenedShare, 450.5 / 900, accuracy: 1e-9)
        let s2 = try XCTUnwrap(signals["s2"])
        XCTAssertEqual(s2.itemsDismissed, 1)
        XCTAssertEqual(s2.itemsSeen, 2, "an unknown event's item still counts as seen, as rank.py would")
        XCTAssertEqual(s2.dismissRate, 0.5, accuracy: 1e-9)
    }

    func testAMissingLogOrPreferencesFileMeansNothingRecorded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(FollowingSignalLog.signals(contentsOf: directory.appendingPathComponent("engagement.jsonl")), [:])
        XCTAssertEqual(FollowingPreferences.load(from: directory.appendingPathComponent(FollowingPreferences.fileName)), FollowingPreferences())
    }

    func testPreferencesRoundTripThroughTheirFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(FollowingPreferences.fileName)
        var preferences = FollowingPreferences()
        preferences.setMark(.pinned, for: "b")
        preferences.setMark(.pinned, for: "a")
        preferences.setMark(.less, for: "c")
        try preferences.save(to: url)
        XCTAssertEqual(FollowingPreferences.load(from: url), preferences)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? String, "following-preferences.v1")
        XCTAssertEqual(json["pinned"] as? [String], ["a", "b"])
        XCTAssertEqual(json["less"] as? [String], ["c"])
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(FollowingPreferences.load(from: url), FollowingPreferences(), "a damaged file resets to nothing marked")
    }
}
