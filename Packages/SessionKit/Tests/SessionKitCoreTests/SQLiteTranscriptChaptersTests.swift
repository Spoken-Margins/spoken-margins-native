import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #777: the Margins tab names a podcast Margin's chapter from the timeline's chapters alone, without decoding
/// the thousands of transcript segments next to them.
final class SQLiteTranscriptChaptersTests: XCTestCase {
    private var paths: [String] = []
    private var databasePath = ""

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-transcript-chapters-\(UUID().uuidString).sqlite").path
        paths.append(path)
        databasePath = path
        return try SQLiteSessionStore(path: path)
    }

    private func timeline(
        itemId: String, id: String = "timeline", createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [MediaTimelineChapter], segments: Int = 3
    ) -> SourceTranscriptTimeline {
        SourceTranscriptTimeline(
            id: id, itemId: itemId, createdAt: createdAt,
            timeline: TranscriptTimeline(
                segments: (0..<segments).map {
                    MediaTimelineSegment(id: "seg-\($0)", startMs: $0 * 1_000, endMs: $0 * 1_000 + 900, text: "Words \($0).")
                },
                chapters: chapters, durationMs: 3_600_000))
    }

    private func chapter(_ title: String, _ startMs: Int) -> MediaTimelineChapter {
        MediaTimelineChapter(id: "ch-publisher-podcasting_2_json-\(startMs)", title: title, description: "About \(title)", startMs: startMs, transcriptSegmentId: "seg-0")
    }

    func testChaptersComeBackExactlyAsSavedWithoutTheSegments() throws {
        let store = try makeStore()
        let chapters = [chapter("Intro \"quoted\" café ☕", 0), chapter("Interview", 600_000)]
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", chapters: chapters, segments: 2_000))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast"), chapters)
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: "podcast")?.timeline.chapters, chapters)
    }

    func testAnItemWithoutATimelineOrWithoutChaptersHasNone() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "nothing"), [])
        try store.saveTranscriptTimeline(timeline(itemId: "plain", chapters: []))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "plain"), [])
    }

    func testEachItemGetsItsOwnChapters() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(timeline(itemId: "one", id: "t1", chapters: [chapter("One", 0)]))
        try store.saveTranscriptTimeline(timeline(itemId: "two", id: "t2", chapters: [chapter("Two", 5_000)]))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "one").map(\.title), ["One"])
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "two").map(\.title), ["Two"])
    }

    /// `loadTranscriptTimeline(itemId:)` reads the newest record when an item has more than one; so must this.
    func testTheLastSavedTimelineWinsWhenAnItemHasMoreThanOne() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", id: "a", chapters: [chapter("Old", 0)]))
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", id: "b", chapters: [chapter("New", 0)]))
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: "podcast")?.timeline.chapters.map(\.title), ["New"])
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast").map(\.title), ["New"])
    }

    /// The answer is kept between Margins-tab refreshes, so a re-saved timeline (the same record id, in the same
    /// second) and a deleted item must still show up in the next answer.
    func testAChangedOrRemovedTimelineIsNotServedFromTheKeptAnswer() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", chapters: [chapter("Short", 0)]))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast").map(\.title), ["Short"])
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast").map(\.title), ["Short"])
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", chapters: [chapter("A much longer chapter title", 0), chapter("Second", 9_000)]))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast").map(\.title), ["A much longer chapter title", "Second"])
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", chapters: []))
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast"), [])
    }

    // MARK: #2073 — the Item screen read every saved timeline in full on each open

    /// A saved timeline record that the full decoder rejects (its segments are not a list) but whose chapters and
    /// duration are intact. Reading it the full way quarantines it and loses the chapters, so a test that still sees
    /// the chapters, and nothing quarantined, knows the segments were never decoded.
    private func insertSegmentlessRecord(
        id: String, itemId: String, chapters: [MediaTimelineChapter], durationMs: Int?, updatedAt: String
    ) throws {
        let full = timeline(itemId: itemId, id: id, chapters: chapters)
        let data = try JSONEncoder().encode(full)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var inner = try XCTUnwrap(object["timeline"] as? [String: Any])
        inner["segments"] = "not a list of segments"
        if let durationMs { inner["durationMs"] = durationMs } else { inner.removeValue(forKey: "durationMs") }
        object["timeline"] = inner
        let payload = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
            .replacingOccurrences(of: "'", with: "''")
        try StoreRawSQL.execute([
            "INSERT INTO records(kind,id,item_id,payload,updated_at) VALUES('source_transcript_timeline','\(id)','\(itemId)','\(payload)','\(updatedAt)')"
        ], at: databasePath)
    }

    func testTheSummaryHasChaptersAndDurationWithoutDecodingTheSegments() throws {
        let store = try makeStore()
        let chapters = [chapter("Intro", 0), chapter("Interview", 600_000)]
        try insertSegmentlessRecord(id: "t", itemId: "podcast", chapters: chapters, durationMs: 3_600_000, updatedAt: "2000-01-01 00:00:00")
        let summary = try XCTUnwrap(store.loadTranscriptTimelineSummary(itemId: "podcast"))
        XCTAssertEqual(summary.chapters, chapters)
        XCTAssertEqual(summary.durationMs, 3_600_000)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testTheSummaryHasNoDurationWhenTheTimelineHasNone() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "t", itemId: "podcast", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeline: TranscriptTimeline(segments: [], chapters: [chapter("Only", 0)])))
        XCTAssertEqual(try store.loadTranscriptTimelineSummary(itemId: "podcast"),
                       TranscriptTimelineSummary(chapters: [chapter("Only", 0)], durationMs: nil))
        XCTAssertNil(try store.loadTranscriptTimelineSummary(itemId: "nothing"))
    }

    func testTheNewestTimelineIsReadWithoutDecodingTheOlderVersions() throws {
        let store = try makeStore()
        try insertSegmentlessRecord(id: "old", itemId: "podcast", chapters: [chapter("Old", 0)], durationMs: nil, updatedAt: "2000-01-01 00:00:00")
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", id: "new", chapters: [chapter("New", 0)]))
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: "podcast")?.id, "new")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0, "the older version must not be decoded just to be dropped")
    }

    func testAnUnreadableNewestTimelineFallsBackToTheVersionBeforeIt() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", id: "good", chapters: [chapter("Good", 0)]))
        try StoreRawSQL.execute([
            "INSERT INTO records(kind,id,item_id,payload,updated_at) VALUES('source_transcript_timeline','broken','podcast','not json','2999-01-01 00:00:00')"
        ], at: databasePath)
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: "podcast")?.id, "good")
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertEqual(try store.loadTranscriptTimelineChapters(itemId: "podcast").map(\.title), ["Good"])
    }

    func testTheSummaryOfAnUnreadableNewestTimelineIsTheVersionBeforeIt() throws {
        let store = try makeStore()
        try store.saveTranscriptTimeline(timeline(itemId: "podcast", id: "good", chapters: [chapter("Good", 0)]))
        try StoreRawSQL.execute([
            "INSERT INTO records(kind,id,item_id,payload,updated_at) VALUES('source_transcript_timeline','broken','podcast','not json','2999-01-01 00:00:00')"
        ], at: databasePath)
        XCTAssertEqual(try store.loadTranscriptTimelineSummary(itemId: "podcast")?.chapters.map(\.title), ["Good"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
    }
}
