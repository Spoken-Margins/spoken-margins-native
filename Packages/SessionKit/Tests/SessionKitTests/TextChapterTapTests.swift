import XCTest
@testable import SessionKit

/// #3362: the playback Timeline of a text item lists time chapters from a stored render as well as map chapters.
/// A tap on one of those used to fail in a live-speech session because only the map was searched.
final class TextChapterTapTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "timeline": ["chapter_timing", "transcript_segments", "media_time"]
        ]
    )
    private let text = "One. Two. Three."

    private func makeEngine(timeline: Bool) throws -> (SessionEngine, RecordingAudioClient) {
        let item = Item(id: "item-3362", title: "Pill", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let listeningMap = ListeningMap(id: "map-3362", itemId: item.id, overview: "Map", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0)
        ])
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: listeningMap])
        if timeline {
            try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
                id: "t-3362", itemId: item.id, createdAt: Date(),
                timeline: TranscriptTimeline(
                    segments: [
                        MediaTimelineSegment(id: "s1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 4, text: "One."),
                        MediaTimelineSegment(id: "s2", startMs: 1_000, endMs: 2_000, startChar: 5, endChar: 9, text: "Two."),
                        MediaTimelineSegment(id: "s3", startMs: 2_000, endMs: 3_000, startChar: 10, endChar: 16, text: "Three.")
                    ],
                    chapters: [MediaTimelineChapter(id: "ch-time-3", title: "Three", startMs: 2_000, transcriptSegmentId: "s3")],
                    durationMs: 3_000)))
        }
        let audio = RecordingAudioClient()
        return (SessionEngine(profile: profile, repository: repo, audio: audio), audio)
    }

    func testTimeChapterFromAStoredRenderSeeksALiveSpeechSessionByItsSegmentText() throws {
        let (engine, audio) = try makeEngine(timeline: true)
        _ = try engine.startSession(itemId: "item-3362")
        XCTAssertEqual(engine.currentSession?.currentTargetType, .itemTextTTS)

        let jumped = try engine.jumpToChapter(chapterId: "ch-time-3")

        XCTAssertEqual(engine.currentSession?.position.charOffset, 10)
        XCTAssertEqual(jumped.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(audio.playedOffsets.last, "Overview. Map\n\n".count + 10)
    }

    func testMapChapterStillJumpsByItsCharacterPosition() throws {
        let (engine, _) = try makeEngine(timeline: false)
        _ = try engine.startSession(itemId: "item-3362")
        _ = try engine.jumpToChapter(chapterId: "ch-1")
        XCTAssertEqual(engine.currentSession?.position.charOffset, 0)
    }

    func testUnavailableChapterShowsItsOwnSentenceNotTheGenericLine() {
        XCTAssertEqual(ListenerErrorText.message(for: ChapterJumpUnavailable()), "Couldn't jump to that chapter. Try another one.")
        XCTAssertEqual(ListenerErrorText.message(for: SessionKitError.invalidCommandForState("jumpToChapter")), ListenerErrorText.fallback)
    }

    func testAChapterNothingMatchesSaysSo() throws {
        let (engine, _) = try makeEngine(timeline: true)
        _ = try engine.startSession(itemId: "item-3362")
        XCTAssertThrowsError(try engine.jumpToChapter(chapterId: "nope")) {
            XCTAssertEqual($0 as? ChapterJumpUnavailable, ChapterJumpUnavailable())
        }
    }

    /// "Try another one" can't work while a written Margin is open, because no chapter can be reached until it closes.
    func testAnOpenWrittenMarginIsNotReportedAsABadChapter() throws {
        let (engine, _) = try makeEngine(timeline: true)
        _ = try engine.startSession(itemId: "item-3362")
        _ = try engine.beginWrittenInterjection()
        XCTAssertThrowsError(try engine.jumpToChapter(chapterId: "ch-1")) {
            XCTAssertEqual($0 as? SessionKitError, .invalidCommandForState("jumpToChapter"))
            XCTAssertNotEqual(ListenerErrorText.message(for: $0), ChapterJumpUnavailable().errorDescription)
        }
    }

    func testNoSessionIsNotReportedAsABadChapter() throws {
        let (engine, _) = try makeEngine(timeline: true)
        XCTAssertThrowsError(try engine.jumpToChapter(chapterId: "ch-1")) {
            XCTAssertNotEqual($0 as? ChapterJumpUnavailable, ChapterJumpUnavailable())
        }
    }
}
