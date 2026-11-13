import Foundation
import XCTest
import SessionKit

/// The inventory behind `TextSpeechAtTheEndTests` (#4067), shared by the host run with a stand-in client
/// (`SessionKitCoreTests`, which also runs on Linux) and the run with the real `SystemSpeechPlaybackClient`
/// (`SessionKitTests`, Mac only). Every public `SessionEngine` entry point that can start item text speech is
/// driven from the end of the text, and none may fail.
public enum TextSpeechAtTheEndInventory {
    private static let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "timeline": ["chapter_timing"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private static let body = "First sentence. Second sentence. Third sentence."
    private static let article = Item(
        id: "item-article", title: "Article", mediaType: "text",
        text: TextSpeechAtTheEndInventory.body,
        externalReference: nil, status: "ready"
    )
    /// Text whose last characters are not speakable: a place in them has nothing left to read, short of the end.
    private static let paddedArticle = Item(
        id: "item-padded", title: "Padded", mediaType: "text",
        text: TextSpeechAtTheEndInventory.body + "\n\n   \n",
        externalReference: nil, status: "ready"
    )

    /// A client that starts nothing, with the real one's refusal: no speakable text from the offset on.
    public final class RefusingAtTheEndSpeech: AudioPlaybackClient {
        var source = ""
        /// Whether the client still reports where its last speech started once it is stopped, as the on-device
        /// (Supertonic) voice does; the system speech client reports nothing.
        let keepsLastOffsetAfterStop: Bool
        private var lastStart: Int?
        /// With `keepsLastOffsetAfterStop`, an earlier speech (the article playing before the Margin was tapped) started at 5.
        public init(keepsLastOffsetAfterStop: Bool = false) {
            self.keepsLastOffsetAfterStop = keepsLastOffsetAfterStop
            lastStart = keepsLastOffsetAfterStop ? 5 : nil
        }
        public func currentCharOffset() -> Int? { keepsLastOffsetAfterStop ? lastStart : nil }
        private(set) var starts: [Int] = []
        /// How often the speech was stopped: a refused start must not leave the old speech running.
        public private(set) var stops = 0
        public func prepareSpeechText(_ text: String) throws -> String { source = text; return text }
        public func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
        public func play(targetId: String, from charOffset: Int) throws {
            let rest = source.dropFirst(max(0, charOffset))
            guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionKitError.invalidCommandForState("playback_text_empty")
            }
            starts.append(charOffset)
            lastStart = charOffset
        }
        public func play(targetId: String, seekingTo charOffset: Int) throws { try play(targetId: targetId, from: charOffset) }
        public func pause() throws {}
        public func stop() throws { stops += 1 }
    }

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private struct Rig {
        let engine: SessionEngine
        let repository: InMemorySessionRepository
        let item: Item
    }

    private static func makeRig(_ item: Item, audio: AudioPlaybackClient) throws -> Rig {
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio, recorder: Recorder())
        _ = try engine.startSession(itemId: item.id)
        return Rig(engine: engine, repository: repository, item: item)
    }

    /// The place is the end of the text, or inside its unspeakable tail, with the engine paused there.
    private static func moveToTheEnd(_ rig: Rig, tail: Int = 0) throws {
        let count = rig.item.text?.count ?? 0
        _ = try rig.engine.pause()
        _ = try rig.engine.seekText(toCharOffset: count - tail)
        XCTAssertEqual(rig.engine.snapshot.status, .paused)
    }

    /// The listener is at the end: the item is finished and paused, and the progress tick agrees.
    private static func assertLandedAtTheEnd(_ rig: Rig, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(rig.engine.snapshot.status, .paused, "\(what): paused at the end", file: file, line: line)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished, "\(what): the item is finished", file: file, line: line)
        XCTAssertEqual(rig.engine.currentSession?.completionPercent, 100, "\(what): at 100%", file: file, line: line)
        XCTAssertNil(rig.engine.snapshot.lastFailure, "\(what): no failure banner", file: file, line: line)
    }

    private static func savedWrittenMargin(_ rig: Rig) throws -> Interjection {
        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "A written note.")
        let sessionId = try XCTUnwrap(rig.engine.currentSession?.id)
        return try XCTUnwrap(rig.repository.loadInterjections(sessionId: sessionId).last)
    }

    // MARK: the inventory, for any client

    public static func run(
        audio makeAudio: () -> AudioPlaybackClient,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Resume (Play, the lock screen, a route change) from the end of the text.
        do {
            let rig = try makeRig(article, audio: makeAudio())
            try moveToTheEnd(rig)
            XCTAssertNoThrow(try rig.engine.resumePlayback(), "resume", file: file, line: line)
            try assertLandedAtTheEnd(rig, "resume", file: file, line: line)
        }
        // Resume from inside the unspeakable tail, short of the end.
        do {
            let rig = try makeRig(paddedArticle, audio: makeAudio())
            try moveToTheEnd(rig, tail: 3)
            XCTAssertNoThrow(try rig.engine.resumePlayback(), "resume in the tail", file: file, line: line)
            try assertLandedAtTheEnd(rig, "resume in the tail", file: file, line: line)
        }
        // "Go to this moment" on a written Margin saved at the end of the text (#3930).
        do {
            let rig = try makeRig(article, audio: makeAudio())
            try moveToTheEnd(rig)
            let margin = try savedWrittenMargin(rig)
            XCTAssertNoThrow(try rig.engine.playInterjectionAnchor(margin), "go to this moment", file: file, line: line)
            try assertLandedAtTheEnd(rig, "go to this moment", file: file, line: line)
        }
        // A restart in place (a speech setting changed) while the place is the end.
        do {
            let rig = try makeRig(article, audio: makeAudio())
            try moveToTheEnd(rig)
            XCTAssertNoThrow(try rig.engine.resumePlayback(), "resume before restart", file: file, line: line)
            XCTAssertNoThrow(try rig.engine.restartPlaybackFromCurrentPosition(), "restart in place", file: file, line: line)
            try assertLandedAtTheEnd(rig, "restart in place", file: file, line: line)
        }
        // The moves that already end at the end instead of starting: they stay that way.
        do {
            let rig = try makeRig(article, audio: makeAudio())
            _ = try rig.engine.resumePlayback()
            XCTAssertNoThrow(try rig.engine.seekText(toCharOffset: article.text?.count ?? 0), "seek to the end", file: file, line: line)
            XCTAssertNoThrow(try rig.engine.skipForward(unit: "paragraph", minimumDistance: 0), "skip at the end", file: file, line: line)
        }
        // From the end, the listener can still start the item again from the top.
        do {
            let rig = try makeRig(article, audio: makeAudio())
            try moveToTheEnd(rig)
            XCTAssertNoThrow(try rig.engine.resumePlayback(), "resume", file: file, line: line)
            _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
            XCTAssertNoThrow(try rig.engine.playSourceFromBeginning(), "play from the beginning", file: file, line: line)
            XCTAssertEqual(rig.engine.snapshot.status.isPlaybackActive, true, "it plays again")
            _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
            XCTAssertNotEqual(rig.engine.currentSession?.phase, .finished, "the end was left behind")
        }
    }


    /// A Margin whose place is the end of an AI answer or an interjection summary (#4199): the same refusal as for an
    /// item's text, answered the same way. The engine has one answer for "nothing left to read" across every text
    /// target, so the generated turns land at the end of the turn, paused, without the error banner.
    public static func generatedTurnMarginAtTheEnd(
        audio makeAudio: () -> AudioPlaybackClient,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let cases: [(InterjectionTargetType, String, TargetType, SessionPhase)] = [
            (.assistantTurn, "assistant_response", .assistantTurnTTS, .aiResponsePlayback),
            (.summaryTurn, "interjection_summary", .summaryTurnTTS, .summaryPlayback)
        ]
        for (marginTarget, turnType, speechTarget, phase) in cases {
            let what = "\(marginTarget.rawValue)"
            let session = Session(
                id: "session-\(what)", itemId: article.id, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: article.id, position: Position(),
                completionPercent: 0, playbackRate: 1
            )
            let turnText = "First response. Second response."
            // Decoded: the turn's memberwise initializer is not public, and its stored form is what the app saves.
            let turnJSON: [String: Any] = [
                "id": "turn-\(what)", "sessionId": session.id, "role": "assistant", "turnType": turnType, "status": "complete",
                "summary": "Brief.", "text": turnText + "\n\n   \n", "sourceInterjectionIds": [String]()
            ]
            let turn = try JSONDecoder().decode(ConversationTurn.self, from: JSONSerialization.data(withJSONObject: turnJSON))
            let margin = Interjection(
                id: "margin-\(what)", itemId: article.id, sessionId: session.id, targetType: marginTarget, targetId: turn.id,
                createdAt: Date(), roughPercent: 100,
                anchor: Anchor(anchorType: .turn, startChar: turnText.count, endChar: turnText.count, anchorBefore: "Second response.", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "A note.",
                cleanedTranscript: nil, displayText: "A note.", status: "active"
            )
            let repository = InMemorySessionRepository(
                items: [article.id: article], sessions: [session.id: session], interjections: [margin.id: margin], turns: [turn.id: turn]
            )
            let engine = SessionEngine(profile: profile, repository: repository, audio: makeAudio(), recorder: Recorder())

            XCTAssertNoThrow(try engine.playInterjectionAnchor(margin), "\(what): go to the Margin at the end", file: file, line: line)
            _ = try engine.syncPlaybackProgress(coalescingWrites: true)
            XCTAssertEqual(engine.currentSession?.currentTargetType, speechTarget, "\(what): on the generated turn", file: file, line: line)
            XCTAssertEqual(engine.snapshot.status, .paused, "\(what): paused at the end of the turn", file: file, line: line)
            XCTAssertEqual(engine.currentSession?.phase, phase, "\(what): still in the turn", file: file, line: line)
            XCTAssertNil(engine.snapshot.lastFailure, "\(what): no failure banner", file: file, line: line)
            XCTAssertEqual(engine.currentSession?.position.charOffset, turnText.count, "\(what): the place is the end, not the top", file: file, line: line)
            // The rate change restarts speech where it is, and Play resumes from there: neither fails either.
            XCTAssertNoThrow(try engine.restartPlaybackFromCurrentPosition(), "\(what): restart in place", file: file, line: line)
            XCTAssertNoThrow(try engine.resumePlayback(), "\(what): resume", file: file, line: line)
            _ = try engine.syncPlaybackProgress(coalescingWrites: true)
            XCTAssertEqual(engine.snapshot.status, .paused, "\(what): still at the end", file: file, line: line)
            XCTAssertNil(engine.snapshot.lastFailure, "\(what): no failure banner after resume", file: file, line: line)
            XCTAssertEqual(engine.currentSession?.position.charOffset, turnText.count, "\(what): still the end after resume", file: file, line: line)
        }
    }


    public static func moveAwayAfterARefusedStart(
        audio: AudioPlaybackClient, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(article, audio: audio)
        try moveToTheEnd(rig)
        _ = try rig.engine.resumePlayback()
        _ = try rig.engine.seekText(toCharOffset: 16)
        _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertNotEqual(rig.engine.currentSession?.phase, .finished, file: file, line: line)
        XCTAssertLessThan(rig.engine.currentSession?.position.charOffset ?? .max, article.text?.count ?? 0, file: file, line: line)
    }

    /// Speech that is playing when a start inside the unspeakable tail is refused is stopped, not left speaking while
    /// the item reads as finished.
    public static func refusedStartStopsTheOldSpeech(
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let speech = RefusingAtTheEndSpeech()
        let rig = try makeRig(paddedArticle, audio: speech)
        XCTAssertTrue(rig.engine.snapshot.status.isPlaybackActive, file: file, line: line)
        let stopsBefore = speech.stops
        XCTAssertNoThrow(try rig.engine.seekText(toCharOffset: (paddedArticle.text?.count ?? 0) - 3), file: file, line: line)
        XCTAssertGreaterThan(speech.stops, stopsBefore, "the old speech was stopped", file: file, line: line)
        try assertLandedAtTheEnd(rig, "a seek into the tail while playing", file: file, line: line)
    }
}
