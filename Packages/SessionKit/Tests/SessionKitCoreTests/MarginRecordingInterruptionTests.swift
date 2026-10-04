import Foundation
import XCTest
@testable import SessionKit

/// #771: a call, Siri or lost headphones stopped the recorder mid-Margin, while the screen still said
/// "Recording" and Save kept a truncated file without saying so.
final class MarginRecordingInterruptionTests: XCTestCase {
    func testACallAfterFiveSecondsSavesTheMarginCutShort() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true), .saveCutShort)
    }

    func testACallInTheFirstSecondDiscardsIt() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: 0.4, sourceAwaitsResume: true), .discard)
    }

    func testTheSourceResumesOnlyWhenTheCallEndsWithShouldResume() {
        var resuming = MarginRecordingInterruptionPolicy()
        _ = resuming.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true)
        XCTAssertEqual(resuming.handle(.interruptionEnded(shouldResume: true), recordedSeconds: nil, sourceAwaitsResume: true), .resumeSource)

        var staying = MarginRecordingInterruptionPolicy()
        _ = staying.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true)
        XCTAssertEqual(staying.handle(.interruptionEnded(shouldResume: false), recordedSeconds: nil, sourceAwaitsResume: true), .none)
    }

    func testRemovedHeadphonesSaveAndTheSourceStaysPaused() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.routeLost, recordedSeconds: 5, sourceAwaitsResume: true), .saveCutShort)
        XCTAssertEqual(policy.handle(.interruptionEnded(shouldResume: true), recordedSeconds: nil, sourceAwaitsResume: true), .none,
                       "nothing resumes from the speaker")
    }

    func testEventsWithoutARecordingChangeNothing() {
        var policy = MarginRecordingInterruptionPolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: nil, sourceAwaitsResume: false), .none)
        XCTAssertEqual(policy.handle(.routeLost, recordedSeconds: nil, sourceAwaitsResume: false), .none)
        XCTAssertEqual(policy.handle(.interruptionEnded(shouldResume: true), recordedSeconds: nil, sourceAwaitsResume: true), .none,
                       "an interruption that didn't stop a Margin isn't this policy's to resume")
    }

    /// iOS doesn't promise an end for every interruption. A later one with no Margin recording
    /// replaces it, so its end can't resume a source the listener paused.
    func testALostEndIsReplacedByTheNextInterruption() {
        var policy = MarginRecordingInterruptionPolicy()
        _ = policy.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true)
        XCTAssertEqual(policy.handle(.interruptionBegan, recordedSeconds: nil, sourceAwaitsResume: true), .none)
        XCTAssertEqual(policy.handle(.interruptionEnded(shouldResume: true), recordedSeconds: nil, sourceAwaitsResume: true), .none)
    }

    func testAResumeIsDroppedOnceTheListenerActed() {
        var played = MarginRecordingInterruptionPolicy()
        _ = played.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true)
        XCTAssertEqual(played.handle(.interruptionEnded(shouldResume: true), recordedSeconds: nil, sourceAwaitsResume: false), .none,
                       "the listener already pressed Play")

        var recordingAgain = MarginRecordingInterruptionPolicy()
        _ = recordingAgain.handle(.interruptionBegan, recordedSeconds: 5, sourceAwaitsResume: true)
        XCTAssertEqual(recordingAgain.handle(.interruptionEnded(shouldResume: true), recordedSeconds: 2, sourceAwaitsResume: true), .none,
                       "a new Margin is recording")
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
