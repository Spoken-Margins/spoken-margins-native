import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2506: when a Margin's transcription finishes, the app asks for the stored transcript's stretch around it. Cutting
/// the window out decodes a whole timeline (several MB for a podcast), so the app runs `storedSourceContextWindow`
/// through `StoreReader` instead of decoding on the main actor. The answer must be what the main-thread code gave.
final class StoredSourceContextWindowTests: XCTestCase {
    private func withStore(_ body: (SQLiteSessionStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try body(try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)) }
    }

    private func saveTimeline(_ store: SQLiteSessionStore, id: String, itemId: String = "A", segmentTexts: [String]) throws {
        let segments = segmentTexts.enumerated().map { index, text in
            MediaTimelineSegment(id: "\(id)-\(index)", startMs: index * 60_000, endMs: (index + 1) * 60_000, text: text)
        }
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: id, itemId: itemId, createdAt: Date(timeIntervalSince1970: 5),
            timeline: TranscriptTimeline(
                segments: segments,
                chapters: [MediaTimelineChapter(id: "ch", title: "Part", startMs: 120_000, transcriptSegmentId: "\(id)-2")],
                durationMs: segments.count * 60_000)))
    }

    func testTheWindowIsWhatTheMainThreadCodeCutOutOfTheWholeTimeline() throws {
        try withStore { store in
            try saveTimeline(store, id: "t1", segmentTexts: (0..<10).map { "Minute \($0)." })
            // anchor, before, after: the middle, the start (clamped at 0), the end (clamped to the duration), a narrow window.
            let rows: [(anchor: Int, before: Int, after: Int)] = [
                (300_000, 90_000, 120_000), (0, 90_000, 120_000), (590_000, 90_000, 120_000), (300_000, 1_000, 1_000)
            ]
            for row in rows {
                let whole = try XCTUnwrap(store.loadTranscriptTimeline(itemId: "A")).timeline
                let old = SourceAnchorContextResolver.sourceContextWindow(
                    from: whole, anchorMediaTimeMs: row.anchor, windowBeforeMs: row.before, windowAfterMs: row.after)
                let new = try store.storedSourceContextWindow(
                    itemId: "A", anchorMediaTimeMs: row.anchor, windowBeforeMs: row.before, windowAfterMs: row.after)
                XCTAssertNotNil(new, "anchor \(row.anchor)")
                XCTAssertEqual(new?.segments.map(\.id), old?.segments.map(\.id), "anchor \(row.anchor)")
                XCTAssertEqual(new?.chapters.map(\.id), old?.chapters.map(\.id), "anchor \(row.anchor)")
                XCTAssertEqual(new?.durationMs, old?.durationMs, "anchor \(row.anchor)")
            }
            let middle = try XCTUnwrap(store.storedSourceContextWindow(
                itemId: "A", anchorMediaTimeMs: 300_000, windowBeforeMs: 1_000, windowAfterMs: 1_000))
            XCTAssertEqual(middle.segments.map(\.text), ["Minute 4.", "Minute 5."], "only the stretch near the Margin, not the whole transcript")
        }
    }

    func testNoStoredTranscriptOrNothingSaidNearTheMarginAnswersNil() throws {
        try withStore { store in
            XCTAssertNil(try store.storedSourceContextWindow(itemId: "A", anchorMediaTimeMs: 1_000, windowBeforeMs: 90_000, windowAfterMs: 120_000),
                         "an item with no stored transcript")
            try saveTimeline(store, id: "t1", segmentTexts: ["Only minute."])
            XCTAssertNil(try store.storedSourceContextWindow(itemId: "A", anchorMediaTimeMs: 900_000, windowBeforeMs: 1_000, windowAfterMs: 1_000),
                         "a Margin placed long after the transcript ends")
            XCTAssertNil(try store.storedSourceContextWindow(itemId: "B", anchorMediaTimeMs: 1_000, windowBeforeMs: 90_000, windowAfterMs: 120_000),
                         "another item's transcript is not this item's")
        }
    }

    func testAReplacedTranscriptIsReadAgain() throws {
        try withStore { store in
            try saveTimeline(store, id: "t1", segmentTexts: ["First."])
            XCTAssertEqual(try store.storedSourceContextWindow(itemId: "A", anchorMediaTimeMs: 10_000, windowBeforeMs: 5_000, windowAfterMs: 5_000)?.segments.map(\.text), ["First."])
            try saveTimeline(store, id: "t2", segmentTexts: ["Second."])
            XCTAssertEqual(try store.storedSourceContextWindow(itemId: "A", anchorMediaTimeMs: 10_000, windowBeforeMs: 5_000, windowAfterMs: 5_000)?.segments.map(\.text), ["Second."])
        }
    }
}
