import Foundation
import XCTest
@testable import SessionKit

/// #237: when an article's rendered narration can't be played, `canReadText` decides whether its text can be read
/// live instead, and `liveSpeechSession` where that reading starts. The sibling file in SessionKitTests covers the
/// happy paths on a Mac; these are the refusals and the edges of the media timeline, and they run on Linux.
final class PreparedNarrationFallbackRulesTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/narration.m4a")

    private func item(
        id: String = "item-article", media: ItemMedia? = nil, mediaType: String = "text",
        text: String? = "First sentence. Second sentence."
    ) -> Item {
        Item(id: id, title: "Article", mediaType: mediaType, text: text, externalReference: nil, status: "ready", media: media)
    }

    private func narration() -> ItemMedia {
        ItemMedia(sourceType: .generatedTTSPrerendered, url: file.absoluteString, nativeMediaId: file.absoluteString)
    }

    private func session(
        itemId: String = "item-article", targetType: TargetType = .transcriptBackedMedia, targetId: String? = nil,
        charOffset: Int = 0, mediaTimeMs: Int? = 1_650
    ) -> Session {
        Session(
            id: "session", itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: targetType, currentTargetId: targetId ?? file.absoluteString,
            position: Position(charOffset: charOffset, mediaTimeMs: mediaTimeMs), completionPercent: 70, playbackRate: 1
        )
    }

    // MARK: canReadText

    func testASessionOfAnotherItemOrNotOnTheNarrationFileCannotReadThisItemsText() {
        XCTAssertTrue(PreparedNarrationFallback.canReadText(instead: session(), item: item(media: narration())), "precondition")
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(itemId: "another-item"), item: item(media: narration())),
                       "a session of another item would be moved onto this item's text")
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(targetType: .itemTextTTS), item: item(media: narration())),
                       "a session already reading the text has nothing to fall back from")
    }

    func testLiveVoiceNarrationFallsBackOnlyWhileTheSessionPlaysAFile() {
        let live = item(media: ItemMedia(sourceType: .generatedTTSRealtime))
        XCTAssertTrue(PreparedNarrationFallback.canReadText(instead: session(), item: live),
                      "a live-voice item whose session still plays a rendered file")
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(targetId: "https://example.com/episode.mp3"), item: live),
                       "its session plays something other than a file")
    }

    func testRecordedAudioAndAudioFirstItemsNeverFallBackToText() {
        for sourceType in [AudioSourceType.nativeMediaFile, .remoteStream, .browserOwnedMedia] {
            let recorded = item(media: ItemMedia(sourceType: sourceType, url: file.absoluteString))
            XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(), item: recorded), sourceType.rawValue)
        }
        for mediaType in [TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue, "audiobook", "guided_tour"] {
            XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(), item: item(media: narration(), mediaType: mediaType)), mediaType)
        }
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session(), item: item(media: narration(), text: nil)), "no text to read")
    }

    // MARK: liveSpeechSession

    private let timeline = TranscriptTimeline(segments: [
        MediaTimelineSegment(id: "1", startMs: 500, endMs: 1_400, startChar: 0, endChar: 10, text: "First one."),
        MediaTimelineSegment(id: "2", startMs: 2_000, endMs: 3_000, startChar: 16, endChar: 32, text: "Second sentence."),
    ], chapters: [], durationMs: 3_000)

    private func resumeOffset(atMs mediaTimeMs: Int?, timeline: TranscriptTimeline? = nil, charOffset: Int = 0, text: String? = nil) -> Int {
        PreparedNarrationFallback.liveSpeechSession(
            from: session(charOffset: charOffset, mediaTimeMs: mediaTimeMs),
            item: item(text: text ?? "First sentence. Second sentence."),
            timeline: timeline ?? self.timeline
        ).position.charOffset
    }

    func testReadingResumesAtTheNearestWordWhenTheMediaTimeIsOutsideASegment() {
        XCTAssertEqual(resumeOffset(atMs: 100), 0, "before the first segment: its start")
        XCTAssertEqual(resumeOffset(atMs: 1_700), 10, "in the gap after a segment: where that segment ended")
        XCTAssertEqual(resumeOffset(atMs: 9_000), 32, "after the last segment: where it ended")
        XCTAssertEqual(resumeOffset(atMs: 2_000), 16, "exactly at a segment's start")
    }

    func testReadingResumesAtTheRoundedPlaceInsideASegment() {
        // 100 ms into the first segment is 0.667 of 10 characters = 6.67: it rounds to 7, not down to 6.
        XCTAssertEqual(resumeOffset(atMs: 1_100), 7)
        XCTAssertEqual(resumeOffset(atMs: 2_500), 24, "halfway through 16 characters")
    }

    func testASegmentWithNoTextSpanResumesAtItsStart() {
        let empty = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "1", startMs: 0, endMs: 2_000, startChar: 12, endChar: 12, text: "")
        ], chapters: [], durationMs: 2_000)
        XCTAssertEqual(resumeOffset(atMs: 1_000, timeline: empty), 12)
    }

    func testTheSavedCharacterOffsetIsUsedWhenThereIsNoMediaTimeOrNoTimeline() {
        XCTAssertEqual(resumeOffset(atMs: nil, charOffset: 20), 20, "no media time was saved")
        XCTAssertEqual(resumeOffset(atMs: 1_100, timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 0), charOffset: 20), 20,
                       "an empty timeline says nothing")
        let resumed = PreparedNarrationFallback.liveSpeechSession(from: session(charOffset: 20), item: item(), timeline: nil)
        XCTAssertEqual(resumed.position.charOffset, 20, "no timeline")
    }

    func testTheResumePlaceStaysInsideTheTextAndSetsTheCompletion() {
        // The timeline's characters run past the text (the item's text was edited since the narration was rendered).
        let past = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "1", startMs: 0, endMs: 1_000, startChar: 40, endChar: 90, text: "")
        ], chapters: [], durationMs: 1_000)
        let item = item()
        let resumed = PreparedNarrationFallback.liveSpeechSession(from: session(mediaTimeMs: 1_000), item: item, timeline: past)
        XCTAssertEqual(resumed.position.charOffset, item.text?.count, "clamped to the end of the text")
        XCTAssertEqual(resumed.completionPercent, 100)

        let beginning = PreparedNarrationFallback.liveSpeechSession(from: session(mediaTimeMs: 0), item: item, timeline: timeline)
        XCTAssertEqual(beginning.completionPercent, 0)
    }
}
