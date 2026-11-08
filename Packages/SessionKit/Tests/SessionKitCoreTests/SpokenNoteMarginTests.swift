import Foundation
import XCTest
@testable import SessionKit

/// #3664: a Margin added while a spoken note plays sits on the sentence that was playing, and finds that sentence again
/// by what it is, not by when it was heard. The note's joined audio is made again whenever a take is added and will be
/// cut differently by a later record-over (#3109); a Margin that kept only a time would then land on other words.
final class SpokenNoteMarginTests: XCTestCase {
    private let noteId = "note-1"
    private var itemId: String { SpokenNoteItem.itemId(forNoteId: noteId) }

    // MARK: fixtures

    private func note() -> SpokenNote {
        var note = SpokenNote(id: noteId)
        for (id, words) in [("a", ["First thought.", "Second thought."]), ("b", ["Third thought.", "Fourth thought."])] {
            note.appendTake(SpokenNoteTake(
                id: id, audioFileName: "take-\(id).m4a", durationMs: 4_000, createdAt: Date(timeIntervalSince1970: 0),
                sentences: words.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1_000, endMs: $0 * 1_000 + 900) }))
        }
        return note
    }

    /// The takes laid end to end; `firstTakeMs` is how long the joined file's first take is, so a later join can differ.
    private func timeline(firstTakeMs: Int = 4_000) -> SpokenNoteWholeTimeline {
        SpokenNoteWholeTimeline(note: note(), layout: SpokenNoteWholeAudioLayout(
            requested: [], placed: [.init(takeId: "a", startMs: 0, durationMs: firstTakeMs), .init(takeId: "b", startMs: firstTakeMs, durationMs: 4_000)],
            durationMs: firstTakeMs + 4_000))
    }

    private func anchor(segmentId: String?, timeMs: Int?) -> Anchor {
        Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: timeMs, transcriptSegmentId: segmentId)
    }

    private func margin(_ id: String, anchor: Anchor, at seconds: Double, status: String = "active", item: String? = nil) -> Interjection {
        Interjection(
            id: id, itemId: item ?? itemId, sessionId: "session", targetType: .item, targetId: item ?? itemId,
            createdAt: Date(timeIntervalSince1970: seconds), roughPercent: 50, anchor: anchor, audioPath: nil, audioStatus: "none",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil, displayText: "A Margin", status: status)
    }

    // MARK: the sentence, from the id

    func testAMarginNamesItsSentenceByIdEvenWhenItsTimeNowPointsElsewhere() {
        // Recorded in the second sentence of the second take, when it sat at 5 s; the join has since put that take later.
        let recorded = anchor(segmentId: SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 1), timeMs: 5_000)
        let shifted = timeline(firstTakeMs: 6_000)
        XCTAssertEqual(SpokenNoteMargins.sentence(of: recorded, on: shifted), .init(takeIndex: 1, sentenceIndex: 1))
        XCTAssertEqual(shifted.ref(atMs: 5_000), .init(takeIndex: 0, sentenceIndex: 1), "the old time would have named the wrong words")
    }

    func testAMarginWithNoIdOrAGoneSentenceFallsBackToItsTime() {
        let timeline = timeline()
        XCTAssertEqual(SpokenNoteMargins.sentence(of: anchor(segmentId: nil, timeMs: 5_200), on: timeline), .init(takeIndex: 1, sentenceIndex: 1))
        let gone = anchor(segmentId: SpokenNoteMargins.segmentId(takeId: "removed", sentenceIndex: 0), timeMs: 1_200)
        XCTAssertEqual(SpokenNoteMargins.sentence(of: gone, on: timeline), .init(takeIndex: 0, sentenceIndex: 1))
        XCTAssertNil(SpokenNoteMargins.sentence(of: anchor(segmentId: nil, timeMs: nil), on: timeline), "nothing to place it by")
    }

    func testMarginsGroupBySentenceInTheOrderMadeAndLeaveOutWhatIsNotTheListenersLiveMargin() {
        let first = SpokenNoteMargins.segmentId(takeId: "a", sentenceIndex: 0)
        let list = [
            margin("late", anchor: anchor(segmentId: first, timeMs: 0), at: 30),
            margin("early", anchor: anchor(segmentId: first, timeMs: 0), at: 10),
            margin("deleted", anchor: anchor(segmentId: first, timeMs: 0), at: 20, status: "deleted"),
            margin("elsewhere", anchor: anchor(segmentId: first, timeMs: 0), at: 5, item: "another-item"),
            margin("other", anchor: anchor(segmentId: SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 0), timeMs: 4_000), at: 40)
        ]
        let grouped = SpokenNoteMargins.marginIdsBySentence(list, itemId: itemId, on: timeline())
        XCTAssertEqual(grouped, [.init(takeIndex: 0, sentenceIndex: 0): ["early", "late"], .init(takeIndex: 1, sentenceIndex: 0): ["other"]])
    }

    func testTheTimeToPlayFromIsTheSentencesStartOnTheCurrentTimelineAndOnlyForANoteSentence() {
        let id = SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 1)
        let now = timeline(firstTakeMs: 6_000).mediaTimeline
        XCTAssertEqual(SpokenNoteMargins.mediaTimeMs(of: anchor(segmentId: id, timeMs: 5_000), in: now), 7_000)
        XCTAssertNil(SpokenNoteMargins.mediaTimeMs(of: anchor(segmentId: nil, timeMs: 5_000), in: now))
        XCTAssertNil(SpokenNoteMargins.mediaTimeMs(of: anchor(segmentId: "other-1", timeMs: 5_000), in: now), "a podcast's segment is not a note's sentence")
        XCTAssertNil(SpokenNoteMargins.mediaTimeMs(of: anchor(segmentId: id, timeMs: 5_000), in: nil))
    }

    // MARK: through the engine, across a relaunch

    private let profile = RuntimeCapabilityProfile(
        id: "phone", displayName: "Phone",
        capabilities: [
            "sync": ["canonical_persistence"], "playback": ["native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ])

    private final class NoteAudio: AudioPlaybackClient {
        var mediaTimeMs: Int?
        var playing = false
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playing = true }
        func play(targetId: String, from charOffset: Int) throws { playing = true }
        func play(targetId: String, fromMediaTimeMs t: Int) throws { mediaTimeMs = t; playing = true }
        func seek(toMediaTimeMs t: Int) throws { mediaTimeMs = t }
        func pause() throws { playing = false }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: 10_000, anchorConfidence: .mediaTime) }
        }
    }

    private final class NoteRecorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private func engine(repository: InMemorySessionRepository, audio: NoteAudio) -> SessionEngine {
        SessionEngine(profile: profile, repository: repository, audio: audio, recorder: NoteRecorder())
    }

    func testAMarginAddedWhileTheNoteIsPlayingIsAnchoredToItsSentenceAndPlaysThereAfterARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("whole-note-\(UUID().uuidString).m4a")
        try Data("joined".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let item = Item(
            id: itemId, title: "Spoken note", mediaType: SpokenNoteItem.mediaType, text: timeline().text,
            externalReference: SpokenNoteItem.reference(forNoteId: noteId), status: "ready", externalReferenceType: SpokenNoteItem.referenceType,
            media: ItemMedia(sourceType: .nativeMediaFile, url: file.absoluteString, durationMs: 8_000, nativeMediaId: "spoken-note-audio-\(itemId)"))
        let repository = InMemorySessionRepository(items: [item.id: item])
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "t", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1), timeline: timeline().mediaTimeline))

        // The listener is hearing the first sentence of the second take (4.2 s in) and adds a Margin.
        let audio = NoteAudio()
        let playing = engine(repository: repository, audio: audio)
        _ = try playing.startSession(itemId: item.id)
        audio.mediaTimeMs = 4_200
        _ = try playing.beginInterjection()
        _ = try playing.finishInterjection(audioRef: nil)
        let saved = try XCTUnwrap(try repository.loadInterjections(sessionId: try XCTUnwrap(playing.currentSession?.id)).first)
        let wanted = SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 0)
        XCTAssertEqual(saved.anchor.transcriptSegmentId, wanted, "the Margin names the sentence that was playing")
        XCTAssertEqual(SpokenNoteMargins.sentence(of: saved.anchor, on: timeline()), .init(takeIndex: 1, sentenceIndex: 0))

        // Relaunch after the joined audio was made again with the first take longer: the same sentence now sits at 6 s.
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "t", itemId: item.id, createdAt: Date(timeIntervalSince1970: 2), timeline: timeline(firstTakeMs: 6_000).mediaTimeline))
        let relaunchedAudio = NoteAudio()
        let relaunched = engine(repository: repository, audio: relaunchedAudio)
        XCTAssertEqual(SpokenNoteMargins.sentence(of: saved.anchor, on: timeline(firstTakeMs: 6_000)), .init(takeIndex: 1, sentenceIndex: 0))

        let played = try relaunched.playInterjectionAnchor(saved)

        XCTAssertEqual(played.currentMediaTimeMs, 6_000, "at the start of the sentence it was made on, not at the old 4.2 s")
        XCTAssertEqual(relaunchedAudio.mediaTimeMs, 6_000)
    }
}
