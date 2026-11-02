import Foundation
import XCTest
@testable import SessionKit

/// #771: a call, Siri or lost headphones stopped the recorder mid-Margin, while the screen still said
/// "Recording" and Save kept a truncated file without saying so.
final class MarginRecordingInterruptionTests: XCTestCase {
    private func mark(session: String = "session-a", textStart: Int = 31, margins: Int = 1) -> InterruptedSourceMark {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = session
        snapshot.targetId = "item-article"
        snapshot.status = .paused
        snapshot.phase = .itemPlayback
        snapshot.currentTextStart = textStart
        snapshot.activeInterjectionCount = margins
        return InterruptedSourceMark(snapshot)
    }

    /// A call stops a five-second Margin, and the save leaves the source paused at `mark()`.
    private func savedByACall() -> MarginRecordingInterruptionPolicy {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: 5, pausedSource: nil), .saveCutShort)
        policy.sourceSettled(at: mark())
        return policy
    }

    func testACallAfterFiveSecondsSavesTheMarginCutShort() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: 5, pausedSource: nil), .saveCutShort)
    }

    func testACallInTheFirstSecondDiscardsIt() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: 0.4, pausedSource: nil), .discard)
    }

    func testTheSourceResumesOnlyWhenTheCallEndsWithShouldResume() {
        var resuming = savedByACall()
        XCTAssertEqual(resuming.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .resumeSource)

        var staying = savedByACall()
        XCTAssertEqual(staying.handle(.interruptionEnded(.audioStaysStopped), recordedSeconds: nil, pausedSource: mark()), .none)
    }

    func testRemovedHeadphonesSaveAndTheSourceStaysPaused() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.routeLost, recordedSeconds: 5, pausedSource: nil), .saveCutShort)
        policy.sourceSettled(at: mark())
        XCTAssertEqual(policy.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none,
                       "nothing resumes from the speaker")
    }

    /// Codex audit P1 on f11032e: a call saves the Margin, then the headphones go before the call
    /// ends. The end must not play the source from the speaker.
    func testHeadphonesLostDuringTheCallCancelTheResume() {
        var policy = savedByACall()
        XCTAssertEqual(policy.handle(.routeLost, recordedSeconds: nil, pausedSource: mark()), .none)
        XCTAssertEqual(policy.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none,
                       "the headphones went during the call, so nothing resumes from the speaker")
    }

    /// Codex audit P2 on f11032e: during the call the listener opened another session, or moved
    /// this one on. The call's end leaves what they chose alone.
    func testAResumeOnlyPlaysTheSourceTheMarginLeft() {
        var otherSession = savedByACall()
        XCTAssertEqual(otherSession.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil,
                                           pausedSource: mark(session: "session-b")), .none)

        var moved = savedByACall()
        XCTAssertEqual(moved.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil,
                                    pausedSource: mark(textStart: 64)), .none, "the listener skipped or played on")

        var newMargin = savedByACall()
        XCTAssertEqual(newMargin.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil,
                                        pausedSource: mark(margins: 2)), .none, "the listener saved another Margin")
    }

    func testAResumeWaitsForTheSaveToSettle() {
        var policy = MarginRecordingInterruptionPolicy()
        _ = policy.handle(.interruptionBegan, recordedSeconds: 5, pausedSource: nil)
        XCTAssertEqual(policy.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none,
                       "a save that never left the source paused has nothing to resume")

        var failed = MarginRecordingInterruptionPolicy()
        _ = failed.handle(.interruptionBegan, recordedSeconds: 5, pausedSource: nil)
        failed.sourceSettled(at: nil)
        XCTAssertEqual(failed.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none)
    }

    func testEventsWithoutARecordingChangeNothing() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: nil, pausedSource: nil), .none)
        XCTAssertEqual(policy.handle(.routeLost, recordedSeconds: nil, pausedSource: nil), .none)
        policy.sourceSettled(at: mark())
        XCTAssertEqual(policy.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none,
                       "an interruption that didn't stop a Margin isn't this policy's to resume")
    }

    /// iOS doesn't promise an end for every interruption. A later one with no Margin recording
    /// replaces it, so its end can't resume a source the listener paused.
    func testALostEndIsReplacedByTheNextInterruption() {
        var policy = savedByACall()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: nil, pausedSource: mark()), .none)
        XCTAssertEqual(policy.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: mark()), .none)
    }

    func testAResumeIsDroppedOnceTheListenerActed() {
        var played = savedByACall()
        XCTAssertEqual(played.handle(.interruptionEnded(.audioMayStart), recordedSeconds: nil, pausedSource: nil), .none,
                       "the listener already pressed Play")

        var recordingAgain = savedByACall()
        XCTAssertEqual(recordingAgain.handle(.interruptionEnded(.audioMayStart), recordedSeconds: 2, pausedSource: nil), .none,
                       "a new Margin is recording")
    }

    func testOnlyAPausedUnfinishedSourceHasAMark() {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = "session-a"
        snapshot.status = .paused
        snapshot.phase = .itemPlayback
        XCTAssertNotNil(InterruptedSourceMark.paused(in: snapshot))
        snapshot.phase = .finished
        XCTAssertNil(InterruptedSourceMark.paused(in: snapshot), "a finished item is left alone (#142)")
        snapshot.phase = .itemPlayback
        snapshot.status = .playing
        XCTAssertNil(InterruptedSourceMark.paused(in: snapshot))
    }

    // MARK: - The engine leaves the source paused when asked

    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio"]
        ]
    )

    private final class CountingPlayer: AudioPlaybackClient {
        var playCount = 0
        var offset = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playCount += 1 }
        func play(targetId: String, from charOffset: Int) throws { playCount += 1; offset = charOffset }
        func currentCharOffset() -> Int? { offset }
        func pause() throws {}
    }

    private func recordingArticle() throws -> (SessionEngine, CountingPlayer, InMemorySessionRepository, String) {
        let text = "First sentence of the article. Second sentence of the article. Third sentence."
        let item = Item(id: "item-article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let player = CountingPlayer()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: player)
        let started = try engine.startSession(itemId: item.id)
        player.offset = 31
        XCTAssertTrue(try engine.beginInterjection().isRecording)
        return (engine, player, repository, try XCTUnwrap(started.sessionId))
    }

    func testAnInterruptedSaveKeepsTheMarginAndLeavesTheSourcePaused() throws {
        let (engine, player, repository, sessionId) = try recordingArticle()
        let playsBefore = player.playCount

        let saved = try engine.finishInterjection(audioRef: "interjections/cut.m4a", resumesSource: false)

        XCTAssertEqual(saved.status, .paused)
        XCTAssertFalse(saved.isRecording)
        XCTAssertEqual(player.playCount, playsBefore, "the source must not play during the call")
        XCTAssertEqual(try repository.loadInterjections(sessionId: sessionId).map(\.audioPath), ["interjections/cut.m4a"])

        _ = try engine.resumePlayback()
        XCTAssertEqual(player.playCount, playsBefore + 1, "Play resumes the source afterwards")
    }

    func testAnInterruptedDiscardLeavesTheSourcePaused() throws {
        let (engine, player, repository, sessionId) = try recordingArticle()
        let playsBefore = player.playCount

        let cancelled = try engine.cancelInterjection(resumesSource: false)

        XCTAssertEqual(cancelled.status, .paused)
        XCTAssertFalse(cancelled.isRecording)
        XCTAssertEqual(player.playCount, playsBefore)
        XCTAssertTrue(try repository.loadInterjections(sessionId: sessionId).isEmpty)
    }

    func testANormalSaveStillResumes() throws {
        let (engine, player, _, _) = try recordingArticle()
        let playsBefore = player.playCount
        let saved = try engine.finishInterjection(audioRef: "interjections/full.m4a")
        XCTAssertTrue(saved.status.isPlaybackActive)
        XCTAssertEqual(player.playCount, playsBefore + 1)
    }
}
