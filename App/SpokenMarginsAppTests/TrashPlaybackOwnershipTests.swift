import Foundation
import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class TrashPlaybackOwnershipTests: XCTestCase {
    /// The viewed item and the playing item are deliberately different. The older trash test never opened B.
    func testTrashingViewedItemPreservesOtherPlaybackAndUndoDoesNotRestartIt() throws {
        try withLibrary { model, audio, _ in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.openItem(id: "item-pill")
            XCTAssertEqual(model.activeItemId, "item-pill")
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            let playCount = audio.playCount

            model.moveItemToTrash(id: "item-pill")

            XCTAssertNil(model.lastError)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertTrue(model.hasActiveSession, "Narration needs a mini-player session after deleting the viewed item")
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.engine?.currentSession?.id, session)
            XCTAssertEqual(model.engine?.snapshot.itemId, model.snapshot.itemId)
            audio.currentOffset = 5
            model.tickPlaybackProgress()
            XCTAssertEqual(model.snapshot.currentTextStart, 5, "Deleting B must not stop A's progress ticker")

            model.undoLastTrash()
            XCTAssertTrue(model.libraryItems.contains { $0.id == "item-pill" })
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(audio.playCount, playCount, "Undo changes the Library, not the audio transport")
        }
    }

    func testTrashingPlayingItemWhileViewingAnotherClosesItsSessionAndPreservesItsPlace() throws {
        try withLibrary { model, audio, database in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            model.openItem(id: "item-pill")
            audio.currentOffset = 5
            let playCount = audio.playCount

            model.moveItemToTrash(id: playingItem)

            XCTAssertNil(model.lastError)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.itemId, "Deleting A must not leave its stopped session in the mini-player")
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertEqual(model.engine?.snapshot.itemId, model.snapshot.itemId)
            XCTAssertEqual(model.selectedItem.id, "item-pill")
            XCTAssertEqual(model.activeItemId, "item-pill")
            let saved = try XCTUnwrap(SQLiteSessionStore(path: database.path).loadSession(id: session))
            XCTAssertEqual(saved.position.charOffset, 5)
            XCTAssertEqual(saved.status, "in_progress")

            model.undoLastTrash()
            XCTAssertTrue(model.libraryItems.contains { $0.id == playingItem })
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertEqual(audio.playCount, playCount)
        }
    }

    func testTrashingViewedItemPreservesAnotherPausedSession() throws {
        try withLibrary { model, audio, _ in
            let playingItem = try startArticle(model)
            model.pause()
            let session = model.snapshot.sessionId
            model.openItem(id: "item-pill")

            model.moveItemToTrash(id: "item-pill")

            XCTAssertNil(model.lastError)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(model.snapshot.status, .paused)
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.engine?.currentSession?.id, session)
        }
    }

    func testTrashingPausedItemWhileViewingAnotherClosesItsSessionWithoutResuming() throws {
        try withLibrary { model, audio, _ in
            let playingItem = try startArticle(model)
            model.pause()
            model.openItem(id: "item-pill")
            let playCount = audio.playCount

            model.moveItemToTrash(id: playingItem)
            model.undoLastTrash()

            XCTAssertNil(model.lastError)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertEqual(model.selectedItem.id, "item-pill")
            XCTAssertEqual(audio.playCount, playCount)
        }
    }

    func testTrashingWithoutPlaybackAndUndoLeaveThePlayerIdle() throws {
        try withLibrary { model, audio, _ in
            model.openItem(id: "item-pill")
            model.moveItemToTrash(id: "item-pill")
            XCTAssertTrue(model.recentlyDeletedItems.contains { $0.id == "item-pill" })
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)

            model.undoLastTrash()

            XCTAssertNil(model.lastError)
            XCTAssertTrue(model.libraryItems.contains { $0.id == "item-pill" })
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.playCount, 0)
        }
    }

    private func startArticle(_ model: Gate1AppModel) throws -> String {
        model.importTitle = "Playing article"
        model.importText = "One. Two. Three. Four."
        model.importTextItem()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.snapshot.status, .playing)
        return try XCTUnwrap(model.snapshot.itemId)
    }

    private func withLibrary(_ body: (Gate1AppModel, TrashOwnershipAudioClient, URL) throws -> Void) throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        SpokenMarginsTerms.recordAcceptance()
        let root = FileManager.default.temporaryDirectory.appending(path: "trash-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "library.sqlite")
        let audio = TrashOwnershipAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, databaseURLOverride: database)
        model.resetAndSeed()
        defer { if model.engine?.currentSession != nil { model.endSession() } }
        try body(model, audio, database)
    }
}

/// A stateful transport boundary: real model, SessionEngine and temporary SQLite; no speech renderer is needed
/// to prove that trash leaves a playing transport without its controlling session, or unexpectedly restarts it.
private final class TrashOwnershipAudioClient: AudioPlaybackClient {
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
    func currentCharOffset() -> Int? { currentOffset }
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetType: .itemTextTTS, targetId: target, textStart: currentOffset,
                         textEnd: currentOffset + 1, anchorConfidence: .textRange)
    }
}
