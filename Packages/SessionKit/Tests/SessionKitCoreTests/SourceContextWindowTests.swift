import XCTest
@testable import SessionKit

final class SourceContextWindowTests: XCTestCase {
    func testStoredTranscriptWindowUsesFullShoulderAndAllowsTimestampGaps() throws {
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "early", startMs: 35_000, endMs: 55_000, text: "Earlier context."),
                MediaTimelineSegment(id: "before", startMs: 70_000, endMs: 120_000, text: "Before."),
                MediaTimelineSegment(id: "after", startMs: 125_000, endMs: 175_000, text: "After."),
                MediaTimelineSegment(id: "late", startMs: 200_000, endMs: 240_000, text: "Later context."),
                MediaTimelineSegment(id: "far", startMs: 500_000, endMs: 550_000, text: "Far away.")
            ],
            chapters: [],
            durationMs: 600_000
        )

        let window = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(from: timeline, anchorMediaTimeMs: 123_000))

        XCTAssertEqual(
            window.segments.map(\.id),
            ["early", "before", "after", "late"],
            "The stored transcript should preserve the full 90-second/120-second shoulder despite normal word-timestamp gaps"
        )
        XCTAssertNil(SourceAnchorContextResolver.sourceContextWindow(from: timeline, anchorMediaTimeMs: 350_000))
    }

    func testSegmentsAtBothInclusiveEdgesAreKept() throws {
        let timeline = TranscriptTimeline(segments: [
            segment("outside-before", 0, 9),
            segment("touch-before", 0, 10),
            segment("overlap-before", 0, 11),
            segment("overlap-after", 29, 40),
            segment("touch-after", 30, 40),
            segment("outside-after", 31, 40)
        ], chapters: [], durationMs: 100)
        let window = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 10
        ))
        XCTAssertEqual(window.segments.map(\.id), ["touch-before", "overlap-before", "overlap-after", "touch-after"])
    }

    func testNoOverlappingSegmentReturnsNil() {
        for segments in [[], [segment("before", 0, 9), segment("after", 31, 40)]] {
            let timeline = TranscriptTimeline(segments: segments, chapters: [], durationMs: 100)
            XCTAssertNil(SourceAnchorContextResolver.sourceContextWindow(
                from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 10
            ))
        }
    }

    func testChaptersRequireStartInsideInclusiveWindow() throws {
        let timeline = TranscriptTimeline(
            segments: [segment("context", 0, 100)],
            chapters: [9, 10, 20, 30, 31].map {
                MediaTimelineChapter(id: "chapter-\($0)", title: "Chapter", startMs: $0, transcriptSegmentId: "context")
            },
            durationMs: 100
        )
        let window = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 10
        ))
        XCTAssertEqual(window.chapters.map(\.startMs), [10, 20, 30])
    }

    func testResultKeepsOriginalDurationWhileSelectionClipsToDuration() throws {
        let timeline = TranscriptTimeline(
            segments: [segment("context", 20, 25), segment("past-duration", 51, 60)],
            chapters: [], durationMs: 50
        )
        let window = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 100
        ))
        let shorterWindow = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 10
        ))
        XCTAssertEqual(shorterWindow.durationMs, 50)
        XCTAssertEqual(window.durationMs, 50)
        XCTAssertEqual(window.segments.map(\.id), ["context"])
    }

    func testNilDurationDoesNotClipWindowEnd() throws {
        let timeline = TranscriptTimeline(
            segments: [segment("after-anchor", 29, 40)], chapters: [], durationMs: nil
        )
        let window = try XCTUnwrap(SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: 20, windowBeforeMs: 10, windowAfterMs: 10
        ))
        XCTAssertEqual(window.segments.map(\.id), ["after-anchor"])
        XCTAssertNil(window.durationMs)
    }

    private func segment(_ id: String, _ startMs: Int, _ endMs: Int) -> MediaTimelineSegment {
        MediaTimelineSegment(id: id, startMs: startMs, endMs: endMs, text: id)
    }
}
