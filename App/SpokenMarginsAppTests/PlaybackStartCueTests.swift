import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #357: a silent start gets one soft chime after 0.8 s, and its time to first audio is recorded per item.
@MainActor
final class PlaybackStartCueTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000)
    private var recorded: [String: String] = [:]
    private var chimes = 0

    private func makeCue() -> PlaybackStartCue {
        PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; return "played" },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )
    }

    private func snapshot(_ itemId: String, _ status: PlaybackStatus) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.itemId = itemId
        snapshot.status = status
        return snapshot
    }

    func testSilentStartChimesOnceAndRecordsTimeToFirstAudio() async throws {
        let cue = makeCue()

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await Task.sleep(for: .seconds(1.2))
        cue.observe(snapshot("article", .starting))
        try await Task.sleep(for: .seconds(1))
        clock += 13
        cue.observe(snapshot("article", .playing))

        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(recorded["lastPlaybackStartCue"], "article:played")
        XCTAssertEqual(recorded["firstAudioMs:article"], "14000")
        XCTAssertEqual(recorded["lastFirstAudioMs"], "14000")
    }

    func testQuickStartHasNoChime() async throws {
        let cue = makeCue()

        cue.observe(snapshot("article", .starting))
        clock += 0.3
        cue.observe(snapshot("article", .playing))
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(chimes, 0)
        XCTAssertNil(recorded["lastPlaybackStartCue"])
        XCTAssertEqual(recorded["firstAudioMs:article"], "300")
    }

    func testAbandonedStartIsNotFirstAudio() {
        let cue = makeCue()

        cue.observe(snapshot("article", .starting))
        clock += 2
        cue.observe(snapshot("article", .paused))

        XCTAssertNil(recorded["firstAudioMs:article"])
        XCTAssertEqual(recorded["lastPlaybackStartEnded"], "article:paused:2000")
    }
}
