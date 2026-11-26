import Foundation
import XCTest
@testable import SessionKit

/// #5358: the owner's queue did not start the next item. His Diagnostics export (Build 37) shows a skip forward that
/// reached the end of an article: playback stopped at the last character, paused, and nothing advanced. A skip past
/// the end of item text left the session in `.itemPlayback`, so the play queue (which advances only on the edge into
/// `.finished`) never saw a finish. A media skip to the end already finished the item.
final class TextSkipToEndFinishesTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "timeline": ["chapter_timing"]
        ]
    )
    private let text = "First sentence. Second sentence. Last one."

    private final class TextAudio: AudioPlaybackClient {
        var charOffset: Int?
        var stops = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset }
        func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
        func currentPlaybackPosition() -> PlaybackPosition? {
            charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }
        func currentCharOffset() -> Int? { charOffset }
        func currentMediaTimeMs() -> Int? { nil }
        func pause() throws {}
        func stop() throws { stops += 1 }
    }

    private func playingNearTheEnd() throws -> (SessionEngine, TextAudio, InMemorySessionRepository) {
        let item = Item(id: "item-a", title: "A", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = TextAudio()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.charOffset = "First sentence. Second sentence. ".count // reading the last sentence
        return (engine, audio, repository)
    }

    func testASkipPastTheLastSentenceFinishesTheItemAndAdvancesTheQueue() throws {
        let (engine, audio, repository) = try playingNearTheEnd()
        let before = engine.snapshot
        XCTAssertTrue(before.status.isPlaybackActive)

        let after = try engine.skipForward(unit: "sentence")

        XCTAssertEqual(after.phase, .finished)
        XCTAssertEqual(after.status, .paused)
        XCTAssertGreaterThan(audio.stops, 0, "the speech stops at the end")
        let saved = try XCTUnwrap(repository.loadSession(id: try XCTUnwrap(after.sessionId)))
        XCTAssertEqual(saved.status, "finished")
        XCTAssertEqual(saved.completionPercent, 100)
        XCTAssertEqual(saved.position.charOffset, text.count)
        XCTAssertTrue(PlayQueueAdvance.shouldAdvance(from: before, to: after))
        XCTAssertEqual(PlayQueueAdvance.decision(from: before, to: after, sleepTimerActive: false, queueHasNext: true), .advance)
    }

    /// #2626 class: a second skip at the end is not a second finish, and keeps the first finish's date.
    func testASecondSkipAtTheEndIsNotASecondFinish() throws {
        let (engine, _, repository) = try playingNearTheEnd()
        let finished = try engine.skipForward(unit: "sentence")
        let completedAt = try repository.loadSession(id: try XCTUnwrap(finished.sessionId))?.completedAt
        XCTAssertNotNil(completedAt, "the first finish is dated")

        let again = try engine.skipForward(unit: "sentence")

        XCTAssertEqual(again.phase, .finished)
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: finished, to: again))
        XCTAssertNil(PlayQueueAdvance.decision(from: finished, to: again, sleepTimerActive: false, queueHasNext: true))
        XCTAssertEqual(try repository.loadSession(id: try XCTUnwrap(again.sessionId))?.completedAt, completedAt)
    }

    func testASkipShortOfTheEndKeepsPlaying() throws {
        let (engine, audio, _) = try playingNearTheEnd()
        audio.charOffset = 0

        let after = try engine.skipForward(unit: "sentence")

        XCTAssertEqual(after.phase, .itemPlayback)
        XCTAssertTrue(after.status.isPlaybackActive)
    }
}
