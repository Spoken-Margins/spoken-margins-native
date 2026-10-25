import Foundation
import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SQLite3
@testable import SpokenMarginsApp

@MainActor
final class TrashPlaybackOwnershipTests: XCTestCase {
    /// The viewed item and the playing item are deliberately different. The older trash test never opened B.
    func testTrashingViewedItemPreservesOtherPlaybackAndUndoDoesNotRestartIt() async throws {
        try await withLibrary { model, audio, database in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            let store = try SQLiteSessionStore(path: database.path)
            var fallback = try store.loadItem(id: "item-pill")
            fallback.id = "000-selection-fallback"
            fallback.title = "A third item"
            try store.saveItem(fallback)
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
            XCTAssertEqual(model.selectedItem.id, fallback.id, "The replacement selection is deliberately not A")
            XCTAssertEqual(model.playbackItemHeaderTitle, "Playing article", "The mini-player must still name A")
            audio.currentOffset = 5
            model.tickPlaybackProgress()
            XCTAssertEqual(model.snapshot.currentTextStart, 5, "Deleting B must not stop A's progress ticker")

            model.undoLastTrash()
            await model.settleLibraryReload()
            XCTAssertTrue(model.libraryItems.contains { $0.id == "item-pill" })
            XCTAssertEqual(model.snapshot.itemId, playingItem)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(audio.playCount, playCount, "Undo changes the Library, not the audio transport")

            model.openPlayback() // The actual mini-player button action.
            XCTAssertEqual(model.screen, .playback)
            XCTAssertEqual(model.activeItemId, playingItem)
            XCTAssertEqual(model.selectedItem.id, playingItem)
            XCTAssertEqual(model.snapshot.sessionId, session)
            model.pause()
            XCTAssertFalse(audio.isPlaying, "The reachable playback controls must control A")
            XCTAssertEqual(model.snapshot.status, .paused)
        }
    }

    func testTrashingPlayingItemWhileViewingAnotherClosesItsSessionAndPreservesItsPlace() async throws {
        try await withLibrary { model, audio, database in
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
            await model.settleLibraryReload()
            XCTAssertTrue(model.libraryItems.contains { $0.id == playingItem })
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertEqual(audio.playCount, playCount)
        }
    }

    func testTrashingViewedItemPreservesAnotherPausedSession() async throws {
        try await withLibrary { model, audio, _ in
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

    func testTrashingPausedItemWhileViewingAnotherClosesItsSessionWithoutResuming() async throws {
        try await withLibrary { model, audio, _ in
            let playingItem = try startArticle(model)
            model.pause()
            model.openItem(id: "item-pill")
            let playCount = audio.playCount

            model.moveItemToTrash(id: playingItem)
            model.undoLastTrash()
            await model.settleLibraryReload()

            XCTAssertNil(model.lastError)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertEqual(model.selectedItem.id, "item-pill")
            XCTAssertEqual(audio.playCount, playCount)
        }
    }

    func testTrashingWithoutPlaybackAndUndoLeaveThePlayerIdle() async throws {
        try await withLibrary { model, audio, _ in
            model.openItem(id: "item-pill")
            model.moveItemToTrash(id: "item-pill")
            XCTAssertTrue(model.recentlyDeletedItems.contains { $0.id == "item-pill" })
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)

            model.undoLastTrash()
            await model.settleLibraryReload()

            XCTAssertNil(model.lastError)
            XCTAssertTrue(model.libraryItems.contains { $0.id == "item-pill" })
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.playCount, 0)
        }
    }

    func testTrashingAnImportThatHasNeverPlayedDoesNotRequireASession() async throws {
        try await withLibrary { model, audio, _ in
            let item = "item-unplayed"
            XCTAssertTrue(model.importBrowserText(BrowserTextHandoff(
                itemId: item,
                captureMode: .selectedText,
                source: BrowserTextSource(url: "https://example.com/unplayed", title: "Unplayed article"),
                text: "Not listening yet.",
                requestedContinuation: BrowserTextContinuation(startSession: false)
            )))
            XCTAssertEqual(model.snapshot.itemId, item)
            XCTAssertNil(model.engine?.currentSession)

            model.moveItemToTrash(id: item)
            model.undoLastTrash()
            await model.settleLibraryReload()

            XCTAssertNil(model.lastError)
            XCTAssertTrue(model.libraryItems.contains { $0.id == item })
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.playCount, 0)
        }
    }

    func testFailedTrashWriteKeepsTheItemAndReportsFailureAfterStoppingPlayback() async throws {
        try await withLibrary { model, audio, database in
            let playingItem = try startArticle(model)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            audio.currentOffset = 5
            // Fail only the real item write, after endSession has saved its independent session record.
            try executeSQL("""
                CREATE TRIGGER refuse_trash BEFORE INSERT ON records
                WHEN NEW.kind = 'item' AND json_extract(NEW.payload, '$.deletedAt') IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'test trash write failure'); END;
                """, database: database)

            model.moveItemToTrash(id: playingItem)

            XCTAssertNotNil(model.lastError)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(model.snapshot.sessionId)
            XCTAssertNil(model.engine?.currentSession)
            XCTAssertNil(model.trashUndo, "A failed trash write must not present a successful Undo action")
            let store = try SQLiteSessionStore(path: database.path)
            XCTAssertNil(try store.loadItem(id: playingItem).deletedAt)
            XCTAssertEqual(try store.loadSession(id: session)?.position.charOffset, 5)
        }
    }

    func testFailedAudioStopDoesNotTrashThePlayingItem() async throws {
        try await withLibrary { model, audio, database in
            let playingItem = try startArticle(model)
            let session = model.snapshot.sessionId
            audio.refusesStop = true
            defer { audio.refusesStop = false }

            model.moveItemToTrash(id: playingItem)

            XCTAssertNotNil(model.lastError)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(model.snapshot.sessionId, session)
            XCTAssertEqual(model.engine?.currentSession?.id, session)
            XCTAssertNil(model.trashUndo)
            XCTAssertNil(try SQLiteSessionStore(path: database.path).loadItem(id: playingItem).deletedAt)
        }
    }

    private func executeSQL(_ sql: String, database: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("test_open_database")
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("test_install_trash_failure")
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

    private func withLibrary(_ body: (Gate1AppModel, TrashOwnershipAudioClient, URL) async throws -> Void) async throws {
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
        try await body(model, audio, database)
    }
}

/// A stateful transport boundary: real model, SessionEngine and temporary SQLite; no speech renderer is needed
/// to prove that trash leaves a playing transport without its controlling session, or unexpectedly restarts it.
private final class TrashOwnershipAudioClient: AudioPlaybackClient {
    private(set) var isPlaying = false
    private(set) var playCount = 0
    private var target: String?
    var currentOffset = 0
    var refusesStop = false

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
    func play(targetId: String, from charOffset: Int) throws {
        target = targetId
        currentOffset = charOffset
        isPlaying = true
        playCount += 1
    }
    func pause() throws { isPlaying = false }
    func stop() throws {
        if refusesStop { throw SessionKitError.persistenceFailed("test_audio_stop") }
        isPlaying = false
    }
    func currentCharOffset() -> Int? { currentOffset }
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetType: .itemTextTTS, targetId: target, textStart: currentOffset,
                         textEnd: currentOffset + 1, anchorConfidence: .textRange)
    }
}
