import Foundation
import XCTest
@testable import SessionKit

/// #237: when an article's rendered narration can't be played, `canReadText` decides whether its text can be read
/// live instead, and `liveSpeechSession` where that reading starts. The sibling file in SessionKitTests covers the
/// happy paths on a Mac; these are the refusals and the edges of the media timeline, and they run on Linux.
final class PreparedNarrationFallbackRulesTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/narration.m4a")

    /// The words sit where `timeline` puts its segments: "First one." is 0..<10 and "Second sentence." is 16..<32.
    private static let articleText = "First one. Next Second sentence."

    private func item(
        id: String = "item-article", media: ItemMedia? = nil, mediaType: String = "text",
        text: String? = PreparedNarrationFallbackRulesTests.articleText
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
            item: item(text: text ?? Self.articleText),
            timeline: timeline ?? self.timeline
        ).position.charOffset
    }

    func testReadingResumesAtTheNearestWordWhenTheMediaTimeIsOutsideASegment() {
        XCTAssertEqual(resumeOffset(atMs: 100), 0, "before the first segment: its start")
        XCTAssertEqual(resumeOffset(atMs: 1_700), 10, "in the gap after a segment: where that segment ended")
        XCTAssertEqual(resumeOffset(atMs: 9_000), 32, "after the last segment: where it ended")
        XCTAssertEqual(resumeOffset(atMs: 2_000), 16, "exactly at a segment's start")
    }

    func testReadingResumesAtTheStartOfTheWordThePlaceFallsInside() {
        // 100 ms into the first segment is 0.667 of 10 characters = 6.67, which rounds to 7: inside "one." (it
        // starts at 6), so reading starts on its "o" and never says "ne." (#2128).
        XCTAssertEqual(resumeOffset(atMs: 1_100), 6)
        XCTAssertEqual(resumeOffset(atMs: 2_500), 23, "halfway through 16 characters is 24, inside \"sentence.\" (23)")
        XCTAssertEqual(resumeOffset(atMs: 2_000), 16, "a place already at a word start stays")
        for ms in stride(from: 500, to: 3_000, by: 37) {
            let offset = resumeOffset(atMs: ms)
            let text = Array(Self.articleText)
            XCTAssertTrue(offset == 0 || offset >= text.count || text[offset - 1].isWhitespace || text[offset].isWhitespace,
                          "\(ms) ms resumed at \(offset), inside a word")
        }
    }

    func testWordStartBacksUpOnlyThroughTheWordTheOffsetIsInside() {
        func start(_ offset: Int, _ text: String) -> Int { PreparedNarrationFallback.wordStart(atOrBefore: offset, in: text) }
        let text = "Hello, world  ok\nnext-one: it's"
        XCTAssertEqual(start(0, text), 0, "the beginning")
        XCTAssertEqual(start(3, text), 0, "inside the first word")
        XCTAssertEqual(start(5, text), 0, "on a comma: punctuation belongs to its word")
        XCTAssertEqual(start(6, text), 6, "on the space after a word")
        XCTAssertEqual(start(7, text), 7, "already at a word start")
        XCTAssertEqual(start(9, text), 7, "inside the second word")
        XCTAssertEqual(start(13, text), 13, "on the second of two spaces")
        XCTAssertEqual(start(15, text), 14, "on the last letter of a short word")
        XCTAssertEqual(start(17, text), 17, "just after a newline")
        XCTAssertEqual(start(21, text), 17, "inside a hyphenated word, which stays whole")
        XCTAssertEqual(start(28, text), 27, "inside a word with an apostrophe")
        XCTAssertEqual(start(text.count, text), text.count, "at the end")
        XCTAssertEqual(start(text.count + 5, text), text.count + 5, "past the end is left to the caller's clamp")
        XCTAssertEqual(start(-3, text), -3, "negative is left to the caller's clamp")
        XCTAssertEqual(start(3, ""), 3, "no text")
        // Offsets count characters, not UTF-16 units or bytes.
        XCTAssertEqual(start(3, "a 👩‍👩‍👧 café ünï"), 3, "the family emoji is one character, so 3 is the space after it")
        XCTAssertEqual(start(7, "a 👩‍👩‍👧 café ünï"), 4, "inside \"café\"")
        XCTAssertEqual(start(11, "a 👩‍👩‍👧 café ünï"), 9, "inside \"ünï\"")
        XCTAssertEqual(start(1, "e\u{301}clair"), 0, "a combining mark is one character with its letter")
        XCTAssertEqual(start(3, "e\u{301}clair"), 0, "inside a word whose first character has a combining mark")
        XCTAssertEqual(start(7, "end.Next one"), 4, "a sentence-ending mark ends the word before it")
        XCTAssertEqual(start(2, "我喜欢听文章 and more"), 2, "Chinese has no spaces to snap to")
        XCTAssertEqual(start(3, "こんにちは world"), 3, "Japanese kana is left as it is")
        XCTAssertEqual(start(8, "Hi. Mr.Smith"), 7, "an abbreviation's mark ends the word, which only costs a short back-up")
        // A run without whitespace longer than the cap is left where it is.
        let url = "go https://example/" + String(repeating: "a", count: 200)
        XCTAssertEqual(start(150, url), 150, "inside a very long run")
        XCTAssertEqual(start(40, url), 3, "inside a long run that is still under the cap")
    }

    func testASegmentWithNoTextSpanResumesAtItsStart() {
        let empty = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "1", startMs: 0, endMs: 2_000, startChar: 11, endChar: 11, text: "")
        ], chapters: [], durationMs: 2_000)
        XCTAssertEqual(resumeOffset(atMs: 1_000, timeline: empty), 11)
    }

    func testTheSavedCharacterOffsetIsUsedWhenThereIsNoMediaTimeOrNoTimeline() {
        // 22 is the space after "Second", so the saved place is already between words and is kept.
        XCTAssertEqual(resumeOffset(atMs: nil, charOffset: 22), 22, "no media time was saved")
        XCTAssertEqual(resumeOffset(atMs: 1_100, timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 0), charOffset: 22), 22,
                       "an empty timeline says nothing")
        let resumed = PreparedNarrationFallback.liveSpeechSession(from: session(charOffset: 22), item: item(), timeline: nil)
        XCTAssertEqual(resumed.position.charOffset, 22, "no timeline")
    }

    func testASavedCharacterOffsetInsideAWordResumesAtThatWordsStart() {
        // A media session's saved character offset was interpolated by time share too (#2128): 20 is inside "Second" (16).
        XCTAssertEqual(resumeOffset(atMs: nil, charOffset: 20), 16, "no media time was saved")
        let resumed = PreparedNarrationFallback.liveSpeechSession(from: session(charOffset: 20), item: item(), timeline: nil)
        XCTAssertEqual(resumed.position.charOffset, 16, "no timeline")
        XCTAssertEqual(resumed.completionPercent, 50)
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
