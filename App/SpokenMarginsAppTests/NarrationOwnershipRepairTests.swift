import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitSupertonic
@testable import SpokenMarginsApp

/// #1337: narration kept playing with no mini player. #1650 fixed the route the Test Desk reproduced (trashing the
/// page being viewed). These cover the layer that should have caught the symptom whatever the route: the app
/// returns to the foreground, or the Live Activity is tapped, with the snapshot empty and the engine's session
/// still playing. Each test makes that state directly, the state the owner's export showed, and checks the repair.
@MainActor
final class NarrationOwnershipRepairTests: XCTestCase {
    /// One test sends the app to the background; the voice governor is shared by the test process (#1679).
    override func tearDown() {
        OnDeviceVoiceGovernor.app.setAppBackgrounded(false)
        super.tearDown()
    }

    func testForegroundShowsTheMiniPlayerAgainForASessionThatIsStillPlaying() throws {
        try withLibrary { model, audio in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.openItem(id: "item-pill") // Open B without stopping A, as in the owner's export.
            loseTheSnapshot(model)
            XCTAssertFalse(model.shouldShowMiniPlayer, "precondition: the symptom, sound with no mini player")
            XCTAssertTrue(audio.isPlaying)
            let playCount = audio.playCount

            model.handleAppBecameActive()

            XCTAssertTrue(model.hasActiveSession)
            XCTAssertTrue(model.shouldShowMiniPlayer)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.engine?.currentSession?.id, session)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(audio.playCount, playCount, "Repair shows the session; it must not restart the audio")

            model.openPlayback() // The mini-player button.
            XCTAssertEqual(model.screen, .playback)
            model.pause()
            XCTAssertFalse(audio.isPlaying, "The repaired controls must control the sound that was playing")
        }
    }

    func testEnteringTheBackgroundShowsTheMiniPlayerAgainForASessionThatIsStillPlaying() throws {
        try withLibrary { model, audio in
            _ = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.screen = .home
            loseTheSnapshot(model)

            model.handleAppBecameInactiveOrBackground(entersBackground: true)

            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertTrue(model.shouldShowMiniPlayer)
            XCTAssertTrue(audio.isPlaying)
        }
    }

    func testTappingTheLiveActivityRecoversTheSessionInsteadOfShowingTheLibrary() throws {
        try withLibrary { model, audio in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.screen = .home
            loseTheSnapshot(model)

            model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback))

            XCTAssertNil(model.lastError, "A playing session must not be reported as 'Nothing is playing right now.'")
            XCTAssertEqual(model.screen, .playback)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.activeItemId, playingItem)
            XCTAssertTrue(audio.isPlaying)
        }
    }

    /// The listener closed it, or paused it: a session the engine isn't playing is not brought back by a repair.
    func testAPausedSessionThatLeftTheSnapshotIsNotBroughtBack() throws {
        try withLibrary { model, audio in
            _ = try startArticle(model)
            model.pause()
            XCTAssertFalse(audio.isPlaying)
            loseTheSnapshot(model)

            let repair = model.reconcileNarrationOwnership(trigger: "foreground")

            XCTAssertEqual(repair, .none)
            XCTAssertFalse(model.hasActiveSession)
            XCTAssertFalse(model.shouldShowMiniPlayer)
        }
    }

    func testNothingPlayingNeedsNoRepairAndAHealthySessionKeepsItsOwnSnapshot() throws {
        try withLibrary { model, audio in
            XCTAssertEqual(model.reconcileNarrationOwnership(trigger: "foreground"), .none)
            XCTAssertFalse(model.hasActiveSession)

            _ = try startArticle(model)
            let session = model.snapshot.sessionId
            XCTAssertEqual(model.reconcileNarrationOwnership(trigger: "foreground"), .none)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertTrue(audio.isPlaying)
        }
    }

    /// A session closed the normal way stays closed: the engine ends it with the audio, so there is nothing to adopt.
    func testASessionClosedFromTheMiniPlayerIsNotRevivedByForeground() throws {
        try withLibrary { model, audio in
            _ = try startArticle(model)
            model.endSession()
            XCTAssertFalse(audio.isPlaying)

            model.handleAppBecameActive()

            XCTAssertFalse(model.hasActiveSession)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertFalse(audio.isPlaying)
        }
    }

    /// What the export now says about the mini player, in the same state.
    func testTheMiniPlayerVisibilityRecordNamesWhyItIsHidden() throws {
        try withLibrary { model, _ in
            _ = try startArticle(model)
            model.screen = .playback
            XCTAssertEqual(model.miniPlayerVisibility, .init(visible: false, reason: "on_playback_screen"))
            model.screen = .home
            XCTAssertEqual(model.miniPlayerVisibility, .init(visible: true, reason: "visible"))
            loseTheSnapshot(model)
            XCTAssertEqual(model.miniPlayerVisibility, .init(visible: false, reason: "no_session"))
        }
    }

    // MARK: - The voice switches while the app has lost the session (#1337)

    /// The export's order of events: the snapshot loses its session, and minutes later Supertonic hands the passage
    /// to the iOS voice. The narration client is the real `SupertonicSpeechPlaybackClient` over a scripted renderer,
    /// so the voice really changes under the model (`narrationDiagnostics()` goes from `on_device` to
    /// `system_voice`). The app comes back to the foreground: the mini player returns for the session that was
    /// playing, the iOS voice carries on from where it took over (no second `play`), and Pause reaches it.
    func testAFallbackVoiceSwitchWhileTheSnapshotIsLostStillGetsTheMiniPlayerAndControlsBack() async throws {
        try await withSupertonicLibrary { model, client, fallback in
            let playingItem = try await startArticleOnSupertonic(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            XCTAssertFalse(client.isSystemVoiceActive, "precondition: the on-device voice is reading")
            model.openItem(id: "item-pill") // Open B without stopping A.
            model.handleAppBecameInactiveOrBackground(entersBackground: true)
            XCTAssertEqual(model.snapshot.sessionId, session, "backgrounding a healthy session leaves it alone")
            let positionBefore = model.snapshot.currentTextStart ?? 0

            loseTheSnapshot(model) // The unexplained playing -> idle.
            XCTAssertFalse(model.shouldShowMiniPlayer, "precondition: the symptom")
            XCTAssertEqual(client.narrationDiagnostics()["clientIntent"], "playing", "precondition: the client still reads")

            XCTAssertTrue(try model.stopOnDeviceRenderingRecordingFallback(
                client, code: "supertonic_resource_pressure", reason: .deviceTooWarm))
            XCTAssertTrue(client.isSystemVoiceActive, "the iOS voice has taken over")
            let handedOver = fallback.playedOffsets
            XCTAssertEqual(handedOver.count, 1)
            fallback.offset = 12 // The iOS voice reads on while the app has no session.

            model.handleAppBecameActive()

            XCTAssertTrue(model.hasActiveSession)
            XCTAssertTrue(model.shouldShowMiniPlayer, "the mini player is back for the session that is still sounding")
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.engine?.currentSession?.id, session)
            XCTAssertTrue(model.snapshot.status.isPlaybackActive)
            XCTAssertEqual(fallback.playedOffsets, handedOver, "Repair shows the session; it must not restart the narration")
            XCTAssertGreaterThan(try XCTUnwrap(model.snapshot.currentTextStart), positionBefore,
                                 "The repaired session sits where the iOS voice is now, not back where Supertonic stopped")

            model.openPlayback() // The mini-player button.
            XCTAssertEqual(model.screen, .playback)
            model.pause()
            XCTAssertGreaterThanOrEqual(fallback.pauseCount, 1, "Pause on the repaired controls reaches the voice that is speaking")
            XCTAssertEqual(client.narrationDiagnostics()["clientIntent"], "paused")

            let events = model.playbackEventRecording.events
            let switched = try XCTUnwrap(events.first { $0.kind == "supertonic.fallback" })
            XCTAssertEqual(switched.fields["code"], "supertonic_resource_pressure")
            XCTAssertEqual(switched.fields["reason"], "device_too_warm")
            let repaired = try XCTUnwrap(events.first { $0.kind == "playback.ownershipRepair" })
            XCTAssertEqual(repaired.fields["repair"], "adopt_engine_session")
            XCTAssertEqual(repaired.fields["clientVoice"], "system_voice", "the record names the voice that was sounding")
        }
    }

    /// The other order: the voice has already switched when the session is lost, and the listener comes back
    /// through the Lock Screen. A tap on the Live Activity finds the session the engine still holds, whichever
    /// voice is reading, instead of "Nothing is playing right now." or the Library.
    func testTappingTheLiveActivityAfterAFallbackVoiceSwitchRecoversTheSession() async throws {
        try await withSupertonicLibrary { model, client, fallback in
            let playingItem = try await startArticleOnSupertonic(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            XCTAssertTrue(try model.stopOnDeviceRenderingRecordingFallback(
                client, code: "supertonic_resource_pressure", reason: .deviceTooWarm))
            XCTAssertTrue(client.isSystemVoiceActive)
            let handedOver = fallback.playedOffsets
            let positionBefore = model.snapshot.currentTextStart ?? 0
            fallback.offset = 12 // The iOS voice reads on while the app has no session.
            model.screen = .home
            loseTheSnapshot(model)

            model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback))

            XCTAssertNil(model.lastError, "A sounding session must not be reported as 'Nothing is playing right now.'")
            XCTAssertEqual(model.screen, .playback)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.activeItemId, playingItem)
            XCTAssertEqual(fallback.playedOffsets, handedOver, "The tap must not restart the narration")
            XCTAssertGreaterThan(try XCTUnwrap(model.snapshot.currentTextStart), positionBefore,
                                 "The recovered session sits where the iOS voice is now")
            XCTAssertEqual(client.narrationDiagnostics()["clientIntent"], "playing")
        }
    }

    /// The state the export showed: the app's snapshot empty while the engine's session and the audio play.
    private func loseTheSnapshot(_ model: Gate1AppModel) {
        model.snapshot = SessionSnapshot()
    }

    private func startArticle(_ model: Gate1AppModel) throws -> String {
        model.importTitle = "Playing article"
        model.importText = "One. Two. Three. Four."
        model.importTextItem()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.snapshot.status, .playing)
        return try XCTUnwrap(model.snapshot.itemId)
    }

    /// Starts the article on the real Supertonic client, which begins asynchronously: waits for the engine to
    /// confirm the start the way the app's own progress sync does.
    private func startArticleOnSupertonic(_ model: Gate1AppModel) async throws -> String {
        model.importTitle = "Playing article"
        model.importText = "One. Two. Three. Four."
        model.importTextItem()
        XCTAssertNil(model.lastError)
        for _ in 0..<150 where model.snapshot.status != .playing {
            try await Task.sleep(for: .milliseconds(20))
            model.syncPlaybackProgressForLifecycle()
        }
        XCTAssertEqual(model.snapshot.status, .playing)
        return try XCTUnwrap(model.snapshot.itemId)
    }

    /// The model over the real SessionEngine and temporary SQLite, narrating through a real
    /// `SupertonicSpeechPlaybackClient` (a scripted renderer, no audible player) whose iOS-voice fallback is a
    /// recording client. The client is also the model's `speechPlaybackClient`, as in the app, so the model reads
    /// its voice and intent.
    private func withSupertonicLibrary(
        _ body: (Gate1AppModel, SupertonicSpeechPlaybackClient, RecordingFallbackAudioClient) async throws -> Void
    ) async throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        SpokenMarginsTerms.recordAcceptance()
        let root = FileManager.default.temporaryDirectory.appending(path: "narration-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = ScriptedSupertonicRenderer(
            template: try silentChunk(in: root), duration: 30, heldRenders: [])
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { true }, fallbackClient: fallback)
        let model = Gate1AppModel(audioPlaybackClient: client, databaseURLOverride: root.appending(path: "library.sqlite"))
        model.speechPlaybackClient = client
        model.resetAndSeed()
        defer {
            if model.engine?.currentSession != nil { model.endSession() }
            try? client.stop()
            renderer.releaseAll()
        }
        try await body(model, client, fallback)
    }

    private func silentChunk(in root: URL) throws -> URL {
        let url = root.appending(path: "chunk.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames = AVAudioFrameCount(8_000 * 30)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func withLibrary(_ body: (Gate1AppModel, OwnershipAudioClient) throws -> Void) throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        SpokenMarginsTerms.recordAcceptance()
        let root = FileManager.default.temporaryDirectory.appending(path: "narration-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = OwnershipAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        defer { if model.engine?.currentSession != nil { model.endSession() } }
        try body(model, audio)
    }
}

/// A stateful transport boundary under the real model, SessionEngine and temporary SQLite.
private final class OwnershipAudioClient: AudioPlaybackClient {
    private(set) var isPlaying = false
    private(set) var playCount = 0
    private var target: String?
    var currentOffset = 0

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
    func play(targetId: String, from charOffset: Int) throws {
        target = targetId
        currentOffset = charOffset
        isPlaying = true
        playCount += 1
    }
    func pause() throws { isPlaying = false }
    func stop() throws { isPlaying = false }
    func currentCharOffset() -> Int? { currentOffset }
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetType: .itemTextTTS, targetId: target, textStart: currentOffset,
                         textEnd: currentOffset + 1, anchorConfidence: .textRange)
    }
}
