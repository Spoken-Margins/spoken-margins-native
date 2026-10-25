import AVFoundation
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
        // Main-queue work left by earlier suites can hold the queue for 2-3 s on a loaded lane Mac (#2104), so the
        // wait is generous; it returns at the first free turn.
        wait(for: [restored], timeout: 10)

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
        try await waitUntil { checks == 2 }

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
        clock += 1 // past the 0.8 s cue; exactly 0.8 rounds just under it
        try await waitUntil { chiming }
        cue.observe(snapshot("article", .paused))

        XCTAssertFalse(chiming)
    }

    /// APA-13 (#1042): every test above replaces the chime and its stop, so the real player never ran. Here the cue
    /// plays its own chime on a `.playback` session, and speech starting stops that player, not a stand-in.
    func testTheRealChimePlaysOnAPlaybackSessionAndStopsWhenSpeechStarts() async throws {
        let session = AVAudioSession.sharedInstance()
        let priorCategory = session.category, priorMode = session.mode, priorOptions = session.categoryOptions
        defer { try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions) }
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        weak var watched: PlaybackStartCue?
        var heldPlayer: AVAudioPlayer?
        let cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            record: { [unowned self] key, value in
                self.recorded[key] = value
                // Runs right after the real player starts. The 0.21 s chime could end by itself before a slow
                // simulator checks it, so it loops silently here: only a stop can end it. The test also holds the
                // player, so letting go of it can't pass for stopping it.
                guard key == "lastPlaybackStartCue", let cue = watched, let player = self.chimePlayer(of: cue) else { return }
                player.volume = 0
                player.numberOfLoops = -1
                heldPlayer = player
            }
        )
        watched = cue

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { recorded["lastPlaybackStartCue"] != nil }
        XCTAssertEqual(recorded["lastPlaybackStartCue"], "article:played", "the real player took the chime")
        let player = try XCTUnwrap(heldPlayer, "the cue keeps its chime player while it plays")
        XCTAssertTrue(player.isPlaying, "the chime is playing")

        cue.observe(snapshot("article", .playing))

        XCTAssertFalse(player.isPlaying, "speech starting stopped the chime's player")
        XCTAssertNil(chimePlayer(of: cue), "and the cue let it go")
    }

    /// The chime never configures the session: on a recording session it stays silent and says why.
    func testTheRealChimeStaysSilentWhenTheSessionIsNotPlayback() async throws {
        let session = AVAudioSession.sharedInstance()
        let priorCategory = session.category, priorMode = session.mode, priorOptions = session.categoryOptions
        defer { try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions) }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        let cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { recorded["lastPlaybackStartCue"] != nil }

        XCTAssertEqual(recorded["lastPlaybackStartCue"], "article:skipped:session_not_playback")
        XCTAssertNil(chimePlayer(of: cue))
        XCTAssertEqual(session.category, .playAndRecord, "the recording session is left as it was")
    }

    /// APA-13 (#1042): the app builds its cue with `init(model:pinned:)`, whose check before the chime is one model
    /// progress tick. No test reached that wiring. Here the model's snapshot says "starting" while its engine has no
    /// start at all, and the request is already 0.8 s old, so the cue is due at once, before the model's own
    /// 500 ms tick. Only the cue's check can bring the snapshot up to date in time to skip the chime.
    func testTheAppsCueChecksTheModelBeforeChiming() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let cue = PlaybackStartCue(model: model, pinned: PinnedDiagnostics(diagnostics: model.runtimeDiagnostics))
        var stale = snapshot("article", .starting)
        stale.playbackRequestedAt = Date().addingTimeInterval(-1)

        model.snapshot = stale
        try await waitUntil { model.snapshot.status != .starting }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotEqual(model.snapshot.status, .starting, "the check brought the snapshot up to date")
        XCTAssertNil(model.diagnostics["lastPlaybackStartCue"], "so no chime played over a start that had already resolved")
        withExtendedLifetime(cue) {}
    }

    /// The cue's own chime player, read the way other app tests read a model's private player.
    private func chimePlayer(of cue: PlaybackStartCue) -> AVAudioPlayer? {
        Mirror(reflecting: cue).children.first { $0.label == "player" }?.value as? AVAudioPlayer
    }

    // MARK: Waiting sound (#357 follow-up)

    private var waitingScheduled: [TimeInterval] = []
    private var waitingActive = false
    private var checks = 0

    /// A cue whose chime and waiting sound are recorded instead of played. `onCheck` runs inside each fresh check.
    private func makeWaitingCue(
        limit: TimeInterval = 60, onCheck: (@MainActor (PlaybackStartCue) -> Void)? = nil
    ) -> PlaybackStartCue {
        var cue: PlaybackStartCue!
        cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: { [unowned self] in self.chimes += 1; return "played" },
            scheduleWaitingCue: { [unowned self] delay in
                self.waitingScheduled.append(delay)
                self.waitingActive = true
                return "scheduled"
            },
            waitingCueDelay: 0.3,
            waitingCuePeriod: 0.2,
            waitingCueLimit: limit,
            stopChime: { [unowned self] in self.waitingActive = false },
            checkNow: { [unowned self] in
                self.checks += 1
                onCheck?(cue)
            },
            record: { [unowned self] key, value in self.recorded[key] = value }
        )
        return cue
    }

    /// A silent start that has been chimed gets the waiting sound, scheduled for the delay after the chime.
    func testSilentStartGetsAWaitingSoundAfterTheChime() async throws {
        let cue = makeWaitingCue()

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { waitingScheduled.count == 1 }

        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(waitingScheduled, [0.3])
        XCTAssertTrue(waitingActive)
        XCTAssertEqual(recorded["lastWaitingCue"], "article:scheduled")
        cue.observe(snapshot("article", .paused)) // ends the cue's checks
    }

    /// Audio that starts before the chime is due gets neither the chime nor the waiting sound.
    func testQuickStartHasNoWaitingSound() async throws {
        let cue = makeWaitingCue()

        cue.observe(snapshot("article", .starting))
        clock += 0.3
        cue.observe(snapshot("article", .playing))
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(waitingScheduled, [])
        XCTAssertFalse(waitingActive)
        XCTAssertNil(recorded["lastWaitingCue"])
    }

    /// The waiting sound stops at once on the first word, a pause, a failure or another item.
    func testWaitingSoundStopsWhenTheStartResolves() async throws {
        for resolution: PlaybackStatus in [.playing, .paused, .failed, .recording] {
            waitingScheduled = []
            waitingActive = false
            let cue = makeWaitingCue()

            cue.observe(snapshot("article", .starting))
            clock += 1
            try await waitUntil { waitingActive }
            cue.observe(snapshot("article", resolution))

            XCTAssertFalse(waitingActive, "a start that ends as \(resolution.rawValue) stops the waiting sound")
        }
    }

    func testAnotherItemStartingStopsTheWaitingSound() async throws {
        let cue = makeWaitingCue()

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { waitingActive }
        cue.observe(snapshot("podcast", .starting))

        XCTAssertFalse(waitingActive, "the old start's sound ends; the new start has its own chime to come")
        cue.observe(snapshot("podcast", .paused)) // ends the new start's pending chime
    }

    /// The cue checks the player just before and just into each repetition, so a late first word stops the sound
    /// within a repetition instead of at the next regular 500 ms tick.
    func testFirstWordFoundByTheCheckBeforeARepetitionStopsTheSound() async throws {
        let cue = makeWaitingCue { [unowned self] cue in
            // The check before the chime and the one during it see silence; the one before the first repetition sees speech.
            if self.checks >= 3 { cue.observe(self.snapshot("article", .playing)) }
        }

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { checks >= 3 }

        XCTAssertFalse(waitingActive)
        XCTAssertEqual(recorded["firstAudioMs:article"], "1000")
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(checks, 3, "a resolved start is not checked again")
    }

    /// A start that never resolves stops repeating, and the diagnostics say so.
    func testHungStartGivesUpOnTheWaitingSound() async throws {
        let cue = makeWaitingCue(limit: 0.9)

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { recorded["lastWaitingCue"] == "article:gave_up" }

        XCTAssertFalse(waitingActive)
    }

    /// The hang probe reads `MainThreadOperationLabels.shared.current` while the main thread is stuck, so the
    /// chime and the waiting sound must each run under their own label, or a hang in them says `operation: none`
    /// (#2512). The waiting sound's label must not still carry the chime's.
    func testChimeAndWaitingSoundRunUnderTheirHangLabels() async throws {
        var chimeLabels: [String] = []
        var waitingLabels: [String] = []
        let cue = PlaybackStartCue(
            now: { [unowned self] in self.clock },
            playChime: {
                chimeLabels.append(MainThreadOperationLabels.shared.current)
                return "played"
            },
            scheduleWaitingCue: { _ in
                waitingLabels.append(MainThreadOperationLabels.shared.current)
                return "scheduled"
            },
            waitingCueDelay: 0.3,
            waitingCuePeriod: 0.2,
            stopChime: {},
            checkNow: {},
            record: { [unowned self] key, value in self.recorded[key] = value }
        )

        cue.observe(snapshot("article", .starting))
        clock += 1
        try await waitUntil { waitingLabels.count == 1 }
        cue.observe(snapshot("article", .paused)) // ends the cue's checks

        XCTAssertEqual(chimeLabels.count, 1)
        XCTAssertEqual(chimeLabels.first?.split(separator: ">").last, "playbackStartChime")
        XCTAssertEqual(waitingLabels.first?.split(separator: ">").last, "playbackWaitingCue")
        XCTAssertFalse(waitingLabels.first?.contains("playbackStartChime") ?? true)
    }

    /// Waits for the cue's timer on a loaded simulator, where a fixed sleep can end before it fires.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for the cue") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
