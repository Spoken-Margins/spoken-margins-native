import Foundation
import XCTest
@testable import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #1337: narration kept playing with no mini player. #1650 fixed the route the Test Desk reproduced (trashing the
/// page being viewed). These cover the layer that should have caught the symptom whatever the route: the app
/// returns to the foreground, or the Live Activity is tapped, with the snapshot empty and the engine's session
/// still playing. Each test makes that state directly, the state the owner's export showed, and checks the repair.
@MainActor
final class NarrationOwnershipRepairTests: XCTestCase {
    func testForegroundShowsTheMiniPlayerAgainForASessionThatIsStillPlaying() throws {
        try withLibrary { model, audio in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.openItem(id: "item-pill") // Open B without stopping A, as in the owner's export.
            loseTheSnapshot(model)
            XCTAssertFalse(model.shouldShowMiniPlayer, "precondition: the symptom, sound with no mini player")
            XCTAssertTrue(audio.isPlaying)
            let playCount = audio.playCount

            model.handleAppBecameInactiveOrBackground(entersBackground: true)
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
