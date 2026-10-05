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

    /// Audit of #580: a start that resolves before the cue is due leaves no pending check behind.
    func testQuickStartRunsNoExtraCheck() async throws {
        var checks = 0
        let cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; return "played" },
            checkNow: { checks += 1 },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("podcast", .starting))
        clock += 0.3
        cue.observe(snapshot("podcast", .playing))
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(checks, 0)
        XCTAssertEqual(chimes, 0)
    }

    /// Audit of #580: the time runs from the listener's request, which the engine stamps on the snapshot.
    func testTimeRunsFromTheRequestTheSnapshotCarries() {
        let cue = makeCue()
        var playing = snapshot("podcast", .playing)
        playing.playbackRequestedAt = clock
        clock += 1.2 // audio-session activation before the engine published the start

        cue.observe(snapshot("podcast", .paused))
        cue.observe(playing)

        XCTAssertEqual(recorded["firstAudioMs:podcast"], "1200")
    }

    /// Audit of #580: when the start is published 0.6 s after the request, the chime is due 0.2 s later, not 0.8 s.
    func testChimeIsDueFromTheRequestNotFromThePublishedStart() async throws {
        let cue = makeCue()
        var starting = snapshot("article", .starting)
        starting.playbackRequestedAt = clock
        clock += 0.6 // audio-session activation and player setup before the engine published the start

        cue.observe(snapshot("article", .paused))
        cue.observe(starting)
        clock += 0.3
        try await Task.sleep(for: .seconds(0.5))

        XCTAssertEqual(chimes, 1, "the chime came within a second of the request")
    }

    /// Audit of #580: an answer on the same item started while the article plays still gets the chime.
    func testAnswerStartedDuringPlaybackChimes() async throws {
        let cue = makeCue()
        var article = snapshot("article", .playing)
        article.targetId = "article"
        var answer = snapshot("article", .starting)
        answer.targetId = "answer"
        answer.playbackRequestedAt = clock

        cue.observe(article)
        cue.observe(answer)
        clock += 1
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(recorded["lastPlaybackStartCue"], "article:played")
    }

    /// Audit of #580: speech that begins while the chime plays stops the chime, found by a check part-way through it
    /// rather than at the next regular 500 ms check.
    func testSpeechStartingUnderTheChimeStopsIt() async throws {
        var cue: PlaybackStartCue!
        var chiming = false
        var checks = 0
        cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; chiming = true; return "played" },
            stopChime: { chiming = false },
            checkNow: { [unowned self] in
                checks += 1
                self.clock += 0.05
                // The check before the chime still sees silence; the one during the chime sees speech.
                cue.observe(self.snapshot("article", checks == 1 ? .starting : .playing))
            },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("article", .starting))
        clock += 0.8
        try await Task.sleep(for: .seconds(1.3))

        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(checks, 2, "one check before the chime and one during it")
        XCTAssertFalse(chiming, "the chime stopped when speech began")
        XCTAssertEqual(recorded["firstAudioMs:article"], "900")
    }

    /// Audit of #580: a start that is paused or replaced while the chime plays stops it too.
    func testPausingDuringTheChimeStopsIt() async throws {
        var chiming = false
        let cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; chiming = true; return "played" },
            stopChime: { chiming = false },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("article", .starting))
        clock += 0.8
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(chiming)
        cue.observe(snapshot("article", .paused))

        XCTAssertFalse(chiming)
    }
}
