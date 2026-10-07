import Foundation
import XCTest
@testable import SessionKit

/// #866: a shared Margin on an article, or a Margin recorded in its text, has a text place. An article played
/// from prepared narration plays as media, and `seekText` refused it, so Add Margin recorded at the old
/// source position instead of at the Margin. The narration timeline says where in the audio a text place is.
final class PreparedNarrationTextSeekTests: XCTestCase {
    private let text = "First sentence. Second sentence. Third sentence."
    private let timeline = TranscriptTimeline(segments: [
        MediaTimelineSegment(id: "1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
        MediaTimelineSegment(id: "2", startMs: 1_000, endMs: 2_000, startChar: 16, endChar: 32, text: "Second sentence."),
        MediaTimelineSegment(id: "3", startMs: 2_000, endMs: 3_000, startChar: 33, endChar: 48, text: "Third sentence.")
    ], chapters: [], durationMs: 3_000)

    func testATextPlaceMapsToTheNarrationTimeAndNeverPastTheRenderedAudio() {
        func ms(_ offset: Int, _ timeline: TranscriptTimeline? = nil) -> Int? {
            PreparedNarrationFallback.mediaTimeMs(textOffset: offset, timeline: timeline ?? self.timeline)
        }
        XCTAssertEqual(ms(0), 0, "the first character")
        XCTAssertEqual(ms(24), 1_500, "halfway through the second sentence")
        XCTAssertEqual(ms(16), 1_000, "exactly at a sentence start")
        XCTAssertEqual(ms(15), 1_000, "the space between two sentences maps to the next one's start")
        XCTAssertEqual(ms(47), 2_933, "the last character of the last sentence")
        XCTAssertNil(ms(48), "the audio ends before text that isn't rendered")
        let partial = TranscriptTimeline(segments: Array(timeline.segments.prefix(2)), chapters: [], durationMs: 2_000)
        XCTAssertEqual(ms(20, partial), 1_250)
        XCTAssertNil(ms(40, partial), "a starter render doesn't reach the third sentence")
        XCTAssertNil(ms(5, TranscriptTimeline(segments: [], chapters: [], durationMs: nil)), "no timeline, no place")
        let unplaced = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "x", startMs: 0, endMs: 1_000, text: "No text positions")
        ], chapters: [], durationMs: 1_000)
        XCTAssertNil(ms(5, unplaced), "segments without text positions can't place text")
    }

    func testSeekTextMovesPreparedNarrationToThatPlaceInTheAudio() throws {
        let (engine, audio) = try narrationEngine()
        let sought = try engine.seekText(toCharOffset: 24)
        XCTAssertEqual(audio.seeks, [1_500], "the narration moves to the Margin's sentence, not the old position")
        XCTAssertEqual(sought.currentMediaTimeMs, 1_500)
        XCTAssertEqual(sought.currentTextStart, 24, "the new Margin's text anchor reads the moved position")
        XCTAssertEqual(sought.status, .playing, "a seek keeps the transport state")
    }

    func testSeekTextRefusesAPlaceTheNarrationDoesntReach() throws {
        let (engine, audio) = try narrationEngine(renderedSegments: 2)
        XCTAssertThrowsError(try engine.seekText(toCharOffset: 40)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("seekText"))
        }
        XCTAssertEqual(audio.seeks, [], "nothing moved, so the caller can tell and not record at the wrong place")
    }

    /// A restored, paused session has no player until it plays: the move is staged, as a media seek is.
    func testSeekTextOnARestoredPausedNarrationStagesThePlace() throws {
        let (engine, audio) = try narrationEngine(playing: false, hasPlayer: false)
        let staged = try engine.seekText(toCharOffset: 24)
        XCTAssertEqual(staged.status, .paused)
        XCTAssertEqual(staged.currentMediaTimeMs, 1_500, "the next start opens the narration at the Margin")
        XCTAssertEqual(staged.currentTextStart, 24)
        XCTAssertEqual(audio.seeks, [], "no player to move")
    }

    // MARK: - Fixture

    private func narrationEngine(renderedSegments: Int = 3, playing: Bool = true, hasPlayer: Bool = true) throws -> (SessionEngine, NarrationAudioClient) {
        let file = FileManager.default.temporaryDirectory.appending(path: "narration-\(UUID().uuidString).m4a")
        try Data("narration".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let item = Item(
            id: "article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: file.absoluteString, durationMs: 3_000, nativeMediaId: file.absoluteString)
        )
        let session = Session(
            id: "session", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: file.absoluteString,
            position: Position(charOffset: 33, mediaTimeMs: 2_000), completionPercent: 66, playbackRate: 1
        )
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1),
            timeline: TranscriptTimeline(segments: Array(timeline.segments.prefix(renderedSegments)), chapters: [], durationMs: 3_000)
        ))
        let audio = NarrationAudioClient()
        audio.hasPlayer = hasPlayer
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["prerendered_audio", "native_media"]]
            ),
            repository: repository, audio: audio
        )
        _ = try engine.inspectSession(sessionId: session.id)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .transcriptBackedMedia, "the narration file is there, so it plays")
        if playing {
            _ = try engine.resumePlayback()
            XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
        }
        return (engine, audio)
    }
}

/// A media player that plays the narration file and records where it was moved.
private final class NarrationAudioClient: AudioPlaybackClient {
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var seeks: [Int] = []
    /// A session restored at launch has no player until it plays, as AVPlayerStreamPlaybackClient reports it.
    var hasPlayer = true

    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        guard hasPlayer else { throw SessionKitError.invalidCommandForState("media_seek_player_unavailable") }
        try seek(toMediaTimeMs: mediaTimeMs)
        return MediaSeekRequest(id: 0, targetId: activeTargetId, requestedMediaTimeMs: mediaTimeMs)
    }

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { activeTargetId = targetId }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        self.mediaTimeMs = mediaTimeMs
    }
    func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        self.mediaTimeMs = mediaTimeMs
        seeks.append(mediaTimeMs)
    }
    func setPlaybackRate(_ rate: Double) throws {}
    func setMixesWithOtherAudio(_ enabled: Bool) throws {}
    func pause() throws {}
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map {
            PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: 3_000, playbackRate: 1, anchorConfidence: .mediaTime)
        }
    }
}
