import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #777: the Margins tab names a podcast Margin's chapter from the timeline's chapters alone, without decoding
/// the thousands of transcript segments next to them.
final class SQLiteTranscriptChaptersTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-transcript-chapters-\(UUID().uuidString).sqlite").path
        paths.append(path)
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
}
