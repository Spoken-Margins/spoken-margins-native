import Combine
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

    /// The cue follows the model's snapshots itself, with no view attached.
    func testFollowsSnapshotsFromThePublisher() {
        let snapshots = PassthroughSubject<SessionSnapshot, Never>()
        let cue = PlaybackStartCue(
            snapshots: snapshots.eraseToAnyPublisher(),
            now: { [unowned self] in self.clock },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        snapshots.send(snapshot("article", .starting))
        clock += 2.5
        snapshots.send(snapshot("article", .playing))

        XCTAssertEqual(recorded["firstAudioMs:article"], "2500")
        withExtendedLifetime(cue) {}
    }

    func testAbandonedStartIsNotFirstAudio() {
        let cue = makeCue()

        cue.observe(snapshot("article", .starting))
        clock += 2
        cue.observe(snapshot("article", .paused))

        XCTAssertNil(recorded["firstAudioMs:article"])
        XCTAssertEqual(recorded["lastPlaybackStartEnded"], "article:paused:2000")
    }

    /// Audit of #580: the model checks the player every 500 ms, so the cue asks for a fresh check before chiming.
    func testFreshCheckBeforeTheChimeSkipsSpeechThatHasAlreadyStarted() async throws {
        var cue: PlaybackStartCue!
        var checks = 0
        cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; return "played" },
            checkNow: { [unowned self] in
                checks += 1
                self.clock += 0.8
                cue.observe(self.snapshot("article", .playing)) // speech began at 600 ms; this check sees it
            },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("article", .starting))
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(checks, 1)
        XCTAssertEqual(chimes, 0)
        XCTAssertNil(recorded["lastPlaybackStartCue"])
        XCTAssertEqual(recorded["firstAudioMs:article"], "800")
    }

    /// Audit of #580: a buffered resume goes straight from paused to playing and still gets a measurement.
    func testStartConfirmedAtOnceIsRecorded() {
        let cue = makeCue()
        recorded["firstAudioMs:podcast"] = "9000" // an older start of the same episode

        cue.observe(snapshot("podcast", .paused))
        cue.observe(snapshot("podcast", .playing))

        XCTAssertEqual(recorded["firstAudioMs:podcast"], "0")
        XCTAssertEqual(recorded["lastFirstAudioMs"], "0")
    }

    /// Audit of #580: Refresh Diagnostics replaces the whole dictionary; the measurements are pinned.
    func testRefreshDiagnosticsKeepsStartMeasurements() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let cue = PlaybackStartCue(model: model, pinned: PinnedDiagnostics(diagnostics: model.runtimeDiagnostics))
        cue.observe(snapshot("article", .paused))
        cue.observe(snapshot("article", .playing))
        XCTAssertEqual(model.diagnostics["firstAudioMs:article"], "0")

        model.refreshDiagnostics() // the Settings button
        let restored = expectation(description: "pinned lines put back on the next main-queue turn")
        DispatchQueue.main.async { DispatchQueue.main.async { restored.fulfill() } }
        wait(for: [restored], timeout: 2)

        XCTAssertEqual(model.diagnostics["firstAudioMs:article"], "0")
        XCTAssertEqual(model.diagnostics["lastFirstAudioMs"], "0")
    }
}
