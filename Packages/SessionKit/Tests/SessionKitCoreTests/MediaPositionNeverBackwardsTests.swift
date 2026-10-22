import Foundation
import XCTest
@testable import SessionKit

/// #2186: a podcast reopened at 42% after the owner had listened to 80% of it. Position saving works when it is
/// asked to (2,811,978 ms survived a kill), so these tests walk the paths that could leave an older value in the
/// store: playing forward, a kill and relaunch, the first samples of a restarted player, a rebuilt player's reset
/// clock, and a Live Activity resume. Whatever the player says, a saved place moves back only for a command the
/// listener gave, and any such move of more than a minute is logged with the command that wrote it.
final class MediaPositionNeverBackwardsTests: XCTestCase {
    private let durationMs = 4_740_000 // 79:00
    private let sixtyThreeMinutes = 63 * 60_000
    private var now = Date(timeIntervalSince1970: 1_000)
    private var logged: [[String: String]] = []

    func testPlayingForwardSavesEachStepAndLogsNothing() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        for minutes in [20, 33, 42, 63] {
            audio.mediaTimeMs = minutes * 60_000
            now += 30
            _ = try engine.syncPlaybackProgress()
            XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, minutes * 60_000)
        }
        XCTAssertTrue(logged.isEmpty, "forward progress is not a backward write: \(logged)")
    }

    func testAKillAndRelaunchKeepsTheSavedPlaceWhateverTheNewPlayerSaysBeforeItStarts() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)

        // The app is killed. A new engine, a fresh player that has loaded nothing and reports its own zero.
        let relaunchedAudio = ProgressAudioClient(durationMs: durationMs)
        relaunchedAudio.mediaTimeMs = 0
        let relaunched = makeEngine(repository: repository, audio: relaunchedAudio)
        _ = try relaunched.inspectSession(sessionId: "session-2186")

        _ = try relaunched.pause() // the Lock Screen or a Live Activity pause before anything played
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
        _ = try relaunched.stopPlayback()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }

    func testALiveActivityResumeAfterARelaunchStartsAtTheSavedPlaceAndKeepsItWhileTheStartIsPending() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()

        let relaunchedAudio = ProgressAudioClient(durationMs: durationMs)
        relaunchedAudio.startStatus = .pending
        let relaunched = makeEngine(repository: repository, audio: relaunchedAudio)
        _ = try relaunched.inspectSession(sessionId: "session-2186")
        XCTAssertEqual(try relaunched.resumePlayback().status, .starting)
        XCTAssertEqual(relaunchedAudio.mediaPlays, [sixtyThreeMinutes])

        // The new player's clock reads zero until it has loaded the stream.
        relaunchedAudio.mediaTimeMs = 0
        for _ in 0..<3 {
            now += 1
            _ = try relaunched.syncPlaybackProgress()
            XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
        }

        relaunchedAudio.startStatus = .confirmed
        relaunchedAudio.mediaTimeMs = sixtyThreeMinutes + 2_000
        now += 1
        XCTAssertEqual(try relaunched.syncPlaybackProgress().status, .playing)
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes + 2_000)
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }

    func testARebuiltPlayersResetClockWhilePlayingNeverRewindsTheSavedPlace() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()

        // A route change or interruption rebuilds the player; for a moment it reports zero.
        audio.mediaTimeMs = 0
        now += 1
        let snapshot = try engine.syncPlaybackProgress()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
        XCTAssertEqual(snapshot.currentMediaTimeMs, sixtyThreeMinutes)
        _ = try engine.pause()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }

    func testAnUnreadablePlayerClockKeepsTheSavedPlace() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()
        audio.mediaTimeMs = nil
        _ = try engine.pause()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, sixtyThreeMinutes)
    }

    func testProgressKeepsBeingSavedAfterEachCommandThatMovesThePlace() throws {
        let commands: [(String, (SessionEngine) throws -> Void)] = [
            ("skipForward 15 s", { _ = try $0.skipForward(unit: "time_15s") }),
            ("skipBack 15 s", { _ = try $0.skipBack(unit: "time_15s") }),
            ("seekMedia", { _ = try $0.seekMedia(toMediaTimeMs: 30 * 60_000) }),
            ("pause and play", { _ = try $0.pause(); _ = try $0.resumePlayback() }),
            ("restart from current position", { _ = try $0.restartPlaybackFromCurrentPosition() }),
            ("play from the beginning", { _ = try $0.playSourceFromBeginning() }),
        ]
        for (name, command) in commands {
            let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
            audio.mediaTimeMs = 20 * 60_000
            _ = try engine.syncPlaybackProgress()
            try command(engine)
            now += 1
            _ = try engine.syncPlaybackProgress() // the command's own start or seek settles
            let landed = try XCTUnwrap(audio.mediaTimeMs, name)
            for minutes in [5, 12, 40] {
                audio.mediaTimeMs = landed + minutes * 60_000
                now += 30
                _ = try engine.syncPlaybackProgress()
                XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, landed + minutes * 60_000,
                               "after \(name), listening \(minutes) minutes on is saved")
            }
        }
    }

    // MARK: - The log

    func testASeekBackOfMoreThanAMinuteIsLoggedWithItsCommand() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()

        _ = try engine.seekMedia(toMediaTimeMs: 20 * 60_000)
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, 20 * 60_000)
        let event = try XCTUnwrap(logged.last)
        XCTAssertEqual(event["event"], "position_backward")
        XCTAssertEqual(event["source"], "seekMedia(toMediaTimeMs:)")
        XCTAssertEqual(event["fromMs"], "\(sixtyThreeMinutes)")
        XCTAssertEqual(event["toMs"], "\(20 * 60_000)")
        XCTAssertEqual(event["sessionId"], "session-2186")
        XCTAssertEqual(try engine.diagnostics()["lastBackwardPositionWrite"]?.contains("source=seekMedia(toMediaTimeMs:)"), true)
    }

    func testAMoveBackOfAMinuteOrLessIsNotLogged() throws {
        let (engine, audio, _) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()
        _ = try engine.skipBack(unit: "time_15s")
        _ = try engine.seekMedia(toMediaTimeMs: sixtyThreeMinutes - 60_000)
        XCTAssertTrue(logged.isEmpty, "\(logged)")

        // Exactly a minute is the line: one millisecond more is logged.
        _ = try engine.seekMedia(toMediaTimeMs: sixtyThreeMinutes - 60_000 - 60_000)
        XCTAssertTrue(logged.isEmpty, "a minute from the last save is not over the line: \(logged)")
        _ = try engine.seekMedia(toMediaTimeMs: sixtyThreeMinutes - 60_000 - 60_000 - 60_001)
        XCTAssertEqual(logged.count, 1)
    }

    func testPlayFromTheBeginningIsLoggedAsThatCommand() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()

        _ = try engine.playSourceFromBeginning()
        XCTAssertEqual(repository.sessions["session-2186"]?.position.mediaTimeMs, 0)
        XCTAssertEqual(logged.last?["source"], "playSourceFromBeginning()")
    }

    func testAWriteAfterARelaunchIsComparedWithWhatTheStoreHeld() throws {
        let (engine, audio, repository) = try playingEngine(startingAt: 10 * 60_000)
        audio.mediaTimeMs = sixtyThreeMinutes
        _ = try engine.syncPlaybackProgress()

        // A new engine has written nothing yet; its first write is still checked against the stored place.
        let relaunched = makeEngine(repository: repository, audio: ProgressAudioClient(durationMs: durationMs))
        _ = try relaunched.inspectSession(sessionId: "session-2186")
        _ = try relaunched.seekMedia(toMediaTimeMs: 5 * 60_000)
        XCTAssertEqual(logged.last?["fromMs"], "\(sixtyThreeMinutes)")
        XCTAssertEqual(logged.last?["toMs"], "\(5 * 60_000)")
    }

    // MARK: - Fixture

    private func playingEngine(startingAt mediaTimeMs: Int) throws -> (SessionEngine, ProgressAudioClient, InMemorySessionRepository) {
        let url = "file:///episodes/long-podcast.mp3"
        let item = Item(
            id: "item-2186", title: "A long episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: url, durationMs: durationMs)
        )
        let session = Session(
            id: "session-2186", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: url,
            position: Position(mediaTimeMs: mediaTimeMs), completionPercent: 10, playbackRate: 1
        )
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let audio = ProgressAudioClient(durationMs: durationMs)
        audio.startStatus = .confirmed
        let engine = makeEngine(repository: repository, audio: audio)
        _ = try engine.inspectSession(sessionId: session.id)
        XCTAssertEqual(try engine.resumePlayback().status, .playing)
        return (engine, audio, repository)
    }

    private func makeEngine(repository: InMemorySessionRepository, audio: ProgressAudioClient) -> SessionEngine {
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
            ),
            repository: repository,
            audio: audio,
            playbackStartTimeout: 5,
            now: { [unowned self] in self.now }
        )
        engine.positionDiagnosticHandler = { [unowned self] in logged.append($0) }
        return engine
    }
}

/// A media player that plays the position it is given and reports whatever its test sets.
private final class ProgressAudioClient: AudioPlaybackClient {
    let durationMs: Int
    var startStatus: PlaybackStartStatus = .pending
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var mediaPlays: [Int] = []

    init(durationMs: Int) { self.durationMs = durationMs }

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, from charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, seekingTo charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        self.mediaTimeMs = mediaTimeMs
        mediaPlays.append(mediaTimeMs)
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}

    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map {
            PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime)
        }
    }

    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }
}
