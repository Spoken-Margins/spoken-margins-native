import XCTest
@testable import SessionKit

/// Prepared audio that opens with a spoken overview is cut back to the item's own text, so Margins and
/// highlights land on the listener's words (#976). The first test moved here from the app's workflow tests.
final class PreparedTextAudioCanonicalizationTests: XCTestCase {
    private let itemText = "First source sentence. Second source sentence."
    private let overview = "Overview. A brief listening map.\n\n"
    private let media = ItemMedia(
        sourceType: .generatedTTSPrerendered,
        url: "file:///tmp/overview-source.caf",
        durationMs: 3_000,
        nativeMediaId: "file:///tmp/overview-source.caf"
    )

    private func preparedWithOverview(chapters: [MediaTimelineChapter]? = nil) -> PreparedTextAudio {
        let prefixLength = overview.count
        let combined = overview + itemText
        return PreparedTextAudio(
            normalizedText: combined,
            media: media,
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "overview", startMs: 0, endMs: 1_000, startChar: 0, endChar: prefixLength, text: overview),
                    MediaTimelineSegment(
                        id: "source-1", startMs: 1_000, endMs: 2_000,
                        startChar: prefixLength, endChar: prefixLength + 22, text: "First source sentence."
                    ),
                    MediaTimelineSegment(
                        id: "source-2", startMs: 2_000, endMs: 3_000,
                        startChar: prefixLength + 23, endChar: combined.count, text: "Second source sentence."
                    )
                ],
                chapters: chapters ?? [
                    MediaTimelineChapter(id: "overview-chapter", title: "Overview", startMs: 0, transcriptSegmentId: "overview"),
                    MediaTimelineChapter(id: "source-chapter", title: "First source sentence", startMs: 1_000, transcriptSegmentId: "source-1")
                ],
                durationMs: 3_000
            )
        )
    }

    func testPreparedSupertonicOverviewNeverReplacesCanonicalItemTextOrOffsets() throws {
        let canonical = try XCTUnwrap(preparedWithOverview().canonicalized(toItemText: itemText))

        XCTAssertEqual(canonical.normalizedText, itemText)
        XCTAssertEqual(canonical.media, media)
        XCTAssertEqual(canonical.timeline.segments[0].startChar, 0)
        XCTAssertEqual(canonical.timeline.segments[0].endChar, 0)
        XCTAssertEqual(canonical.timeline.segments[1].startChar, 0)
        XCTAssertEqual(canonical.timeline.segments[1].endChar, 22)
        XCTAssertEqual(canonical.timeline.segments.last?.endChar, itemText.count)
        XCTAssertEqual(canonical.timeline.chapters.map(\.id), ["source-chapter"])
    }

    func testTheSegmentsKeepTheirTimesAndTheItemsOwnWords() throws {
        let prepared = preparedWithOverview()
        let canonical = try XCTUnwrap(prepared.canonicalized(toItemText: itemText))

        XCTAssertEqual(canonical.timeline.segments.map(\.id), ["overview", "source-1", "source-2"])
        XCTAssertEqual(canonical.timeline.segments.map(\.startMs), [0, 1_000, 2_000])
        XCTAssertEqual(canonical.timeline.segments.map(\.endMs), [1_000, 2_000, 3_000])
        XCTAssertEqual(canonical.timeline.durationMs, 3_000)
        XCTAssertEqual(canonical.timeline.segments[1].text, "First source sentence.")
        XCTAssertEqual(canonical.timeline.segments[2].startChar, 23)
        XCTAssertEqual(canonical.timeline.segments[2].text, "Second source sentence.")
        XCTAssertEqual(canonical.timeline.segments[0].text, overview, "an empty range keeps the spoken text it had")
        XCTAssertEqual(canonical.createdAt, prepared.createdAt)
    }

    func testAChapterIsTitledWithTheFirstSevenWordsOfItsSegment() throws {
        let itemText = "One two three four five six seven eight nine."
        let prefix = "Overview.\n"
        let combined = prefix + itemText
        let prepared = PreparedTextAudio(
            normalizedText: combined,
            media: media,
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(
                        id: "body", startMs: 0, endMs: 1_000,
                        startChar: prefix.count, endChar: combined.count, text: itemText
                    )
                ],
                chapters: [MediaTimelineChapter(id: "c", title: "Old title", description: "kept", startMs: 0, transcriptSegmentId: "body")]
            )
        )

        let chapter = try XCTUnwrap(prepared.canonicalized(toItemText: itemText)?.timeline.chapters.first)

        XCTAssertEqual(chapter.title, "One two three four five six seven")
        XCTAssertEqual(chapter.description, "kept")
        XCTAssertEqual(chapter.transcriptSegmentId, "body")
    }

    func testAChapterPointingAtNoSegmentIsDropped() throws {
        let prepared = preparedWithOverview(chapters: [
            MediaTimelineChapter(id: "orphan", title: "Orphan", startMs: 0, transcriptSegmentId: "no-such-segment"),
            MediaTimelineChapter(id: "source-chapter", title: "Kept", startMs: 1_000, transcriptSegmentId: "source-2")
        ])

        let canonical = try XCTUnwrap(prepared.canonicalized(toItemText: itemText))

        XCTAssertEqual(canonical.timeline.chapters.map(\.id), ["source-chapter"])
    }

    func testWithNoOverviewTheAudioComesBackAsItWas() {
        let prepared = preparedWithOverview()
        let bare = PreparedTextAudio(
            normalizedText: itemText, media: media, timeline: prepared.timeline, createdAt: prepared.createdAt
        )

        XCTAssertEqual(bare.canonicalized(toItemText: itemText), bare)
    }

    func testTextThatIsNotTheEndOfThePreparedTextGivesNothing() {
        let prepared = preparedWithOverview()
        for text in [nil, "", "Other text entirely.", "First source sentence.", itemText + " "] as [String?] {
            XCTAssertNil(prepared.canonicalized(toItemText: text), "\(String(describing: text))")
        }
    }

    func testASegmentWithNoOffsetsStaysInsideTheItemText() throws {
        let prefix = "Overview.\n"
        let prepared = PreparedTextAudio(
            normalizedText: prefix + itemText,
            media: media,
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "bare", startMs: 0, endMs: 500, text: "kept text")],
                chapters: []
            )
        )

        let segment = try XCTUnwrap(prepared.canonicalized(toItemText: itemText)?.timeline.segments.first)

        XCTAssertEqual(segment.startChar, 0)
        XCTAssertEqual(segment.endChar, 0)
        XCTAssertEqual(segment.text, "kept text")
    }
}
