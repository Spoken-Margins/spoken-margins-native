import XCTest
@testable import SessionKit

final class PlaybackChapterLocatorTests: XCTestCase {
    private let opening = Chapter(id: "opening", title: "Opening", startChar: 10, endChar: 20, percent: 0)
    private let pivot = Chapter(id: "pivot", title: "The Pivot", startChar: 20, endChar: 30, percent: 0)

    private func context() -> PlaybackChapterContext {
        PlaybackChapterContext(
            snapshot: SessionSnapshot(), id: "item", title: "A Long Article",
            chapters: [opening, pivot], mediaChapters: [], listeningMapScenes: [],
            turns: [], sessionItemId: nil, sessionChapterId: nil
        )
    }

    func testExactOffsetWinsOverRoundedPercentAndSessionChapter() {
        var c = context()
        c.snapshot.targetType = "item_text_tts"
        c.sessionItemId = c.id
        c.sessionChapterId = pivot.id
        c.snapshot.chapterTitle = pivot.title
        c.snapshot.sourceProgressPercent = 100
        for (offset, expected) in [(-1, opening.id), (10, opening.id), (19, opening.id), (20, pivot.id), (200, pivot.id)] {
            c.snapshot.currentTextStart = offset
            XCTAssertEqual(PlaybackChapterLocator.currentChapter(c)?.id, expected, "offset \(offset)")
        }
        c.chapters = []
        XCTAssertNil(PlaybackChapterLocator.currentChapter(c))
    }

    func testCurrentChapterRequiresMatchingSessionItemThenUsesTitleAndPercent() {
        var c = context()
        c.sessionChapterId = opening.id
        c.snapshot.chapterTitle = pivot.title
        for itemId in [nil, "other", c.id] as [String?] {
            c.sessionItemId = itemId
            XCTAssertEqual(PlaybackChapterLocator.currentChapter(c)?.id, itemId == c.id ? opening.id : pivot.id)
        }
        c.sessionChapterId = "unknown"
        XCTAssertEqual(PlaybackChapterLocator.currentChapter(c)?.id, pivot.id)
        c.snapshot.chapterTitle = "OPENING" // This fallback is case-sensitive.
        XCTAssertEqual(PlaybackChapterLocator.currentChapter(c)?.id, pivot.id)
        c.snapshot.sourceProgressPercent = -1
        XCTAssertEqual(PlaybackChapterLocator.currentChapter(c)?.id, opening.id)
    }

    func testTimelineSourceTargetsIgnoreSessionItemAndRejectTurnPlayback() {
        var c = context()
        c.sessionItemId = "other"
        c.sessionChapterId = opening.id
        c.snapshot.chapterTitle = pivot.title
        c.snapshot.currentTextStart = 20
        for raw in ["item_text_tts", "transcript_backed_media", "browser_owned_media"] {
            c.snapshot.targetType = raw
            XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(opening, context: c), raw)
            XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, context: c), raw)
        }
        for raw in [nil, "summary_turn_tts", "assistant_turn_tts", "unknown"] as [String?] {
            c.snapshot.targetType = raw
            XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineChapter(opening, context: c))
        }
        c.snapshot.targetType = "item_text_tts"
        c.sessionChapterId = "unknown"
        c.snapshot.chapterTitle = "THE PIVOT"
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, context: c))
        c.snapshot.chapterTitle = nil
        c.snapshot.currentTextStart = 10
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(opening, context: c))
        XCTAssertEqual(TargetType.itemTextTTS.rawValue, "item_text_tts")
        XCTAssertEqual(TargetType.transcriptBackedMedia.rawValue, "transcript_backed_media")
        XCTAssertEqual(TargetType.browserOwnedMedia.rawValue, "browser_owned_media")
    }

    func testTurnTimelineUsesSummaryMarkerTargetAndChapterIdentity() {
        var c = context()
        c.turns = [ConversationTurn(id: "turn", sessionId: "session", role: "assistant", turnType: "interjection_summary", status: "ready", chapters: [opening, pivot], sourceInterjectionIds: [])]
        c.snapshot.targetId = "turn"
        c.snapshot.targetType = "summary_turn_tts"
        c.snapshot.chapterTitle = "THE PIVOT"
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, turnId: "turn", context: c))
        XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Ch. 2: THE PIVOT")
        c.snapshot.targetType = "assistant_turn_tts"
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, turnId: "turn", context: c))
        c.turns[0].turnType = "discussion"
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, turnId: "turn", context: c))
        c.sessionItemId = "other"
        c.sessionChapterId = opening.id
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineChapter(opening, turnId: "turn", context: c))
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineChapter(pivot, turnId: "turn", context: c))
        c.snapshot.targetId = "another-turn"
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineChapter(opening, turnId: "turn", context: c))
        XCTAssertEqual(TargetType.summaryTurnTTS.rawValue, "summary_turn_tts")
        XCTAssertEqual(TargetType.assistantTurnTTS.rawValue, "assistant_turn_tts")
    }

    func testHeaderNumbersKnownChaptersAndPreservesItemAndUnknownTitles() {
        var c = context()
        c.snapshot.targetType = "item_text_tts"
        for (reported, expected) in [(" The Pivot ", "Ch. 2: The Pivot"), ("Unknown", "Unknown"), ("the pivot", "Ch. 2: the pivot")] {
            c.snapshot.chapterTitle = reported
            XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), expected)
        }
        c.snapshot.chapterTitle = c.title
        c.snapshot.currentTextStart = 20
        XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Ch. 2: The Pivot")
        c.title = "Why Apple Is Heading Into a Pivotal Moment"
        c.snapshot.targetType = "transcript_backed_media"
        c.snapshot.chapterTitle = c.title
        XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Why Apple Is Heading Into a Pivotal Moment")
        c.snapshot.chapterTitle = "  "
        XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), c.title)
        c.title = ""
        c.snapshot.title = nil
        c.snapshot.chapterTitle = nil
        XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "")
    }

    func testMediaHeadersFilterBothTranscriptMarkersAndSortSceneFallback() {
        var c = context()
        let intro = MediaTimelineChapter(id: "intro", title: "Opening", startMs: 0, transcriptSegmentId: "segment")
        let debate = MediaTimelineChapter(id: "debate", title: "The Debate", startMs: 60_000, transcriptSegmentId: "segment")
        let transcripts = [
            MediaTimelineChapter(id: "ch-transcript-1", title: "Transcript A", startMs: 70_000, transcriptSegmentId: "segment"),
            MediaTimelineChapter(id: "item-ch-transcript-2", title: "Transcript B", startMs: 80_000, transcriptSegmentId: "segment")
        ]
        c.listeningMapScenes = [debate, intro]
        for raw in ["transcript_backed_media", "browser_owned_media"] {
            c.snapshot.targetType = raw
            c.snapshot.chapterTitle = c.title
            c.snapshot.currentMediaTimeMs = 90_000
            c.mediaChapters = transcripts
            XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Ch. 2: The Debate")
            c.mediaChapters = transcripts + [debate, intro]
            c.listeningMapScenes = []
            XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Ch. 2: The Debate")
            c.snapshot.chapterTitle = "The Debate"
            XCTAssertEqual(PlaybackChapterLocator.playbackHeaderTitle(c), "Ch. 2: The Debate")
            c.listeningMapScenes = [debate, intro]
        }
    }

    func testMediaTimelineIgnoresSessionItemAndFallsBackToTitle() {
        var c = context()
        let chapter = MediaTimelineChapter(id: "media", title: "Media", startMs: 0, transcriptSegmentId: "segment")
        c.mediaChapters = [chapter]
        c.sessionItemId = "other"
        c.sessionChapterId = chapter.id
        for raw in ["transcript_backed_media", "browser_owned_media"] {
            c.snapshot.targetType = raw
            XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineMediaChapter(chapter, context: c))
        }
        c.sessionChapterId = "unknown"
        c.snapshot.chapterTitle = "MEDIA"
        XCTAssertTrue(PlaybackChapterLocator.isCurrentTimelineMediaChapter(chapter, context: c))
        for raw in [nil, "item_text_tts", "summary_turn_tts", "assistant_turn_tts"] as [String?] {
            c.snapshot.targetType = raw
            XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineMediaChapter(chapter, context: c))
        }
    }

    func testListeningMapUsesInclusiveStartExclusiveNextStartAndOpenLastScene() {
        var c = context()
        let first = MediaTimelineChapter(id: "first", title: "First", startMs: 10, transcriptSegmentId: "segment")
        let last = MediaTimelineChapter(id: "last", title: "Last", startMs: 20, transcriptSegmentId: "segment")
        c.listeningMapScenes = [last, first]
        for raw in ["transcript_backed_media", "browser_owned_media"] {
            c.snapshot.targetType = raw
            for (time, firstCurrent, lastCurrent) in [(9, false, false), (10, true, false), (19, true, false), (20, false, true), (1_000_000, false, true)] {
                c.snapshot.currentMediaTimeMs = time
                XCTAssertEqual(PlaybackChapterLocator.isCurrentTimelineListeningMapScene(first, context: c), firstCurrent)
                XCTAssertEqual(PlaybackChapterLocator.isCurrentTimelineListeningMapScene(last, context: c), lastCurrent)
            }
        }
        c.snapshot.currentMediaTimeMs = nil
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineListeningMapScene(last, context: c))
        c.snapshot.currentMediaTimeMs = 20
        c.snapshot.targetType = "item_text_tts"
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineListeningMapScene(last, context: c))
        c.snapshot.targetType = "transcript_backed_media"
        c.listeningMapScenes = []
        XCTAssertFalse(PlaybackChapterLocator.isCurrentTimelineListeningMapScene(last, context: c))
    }
}
