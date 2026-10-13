import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class RecordingPresentationContextTests: XCTestCase {
    func testContextUsesCurrentPlaybackPositionAndKeepsTheSessionTitle() {
        var snapshot = SessionSnapshot()
        snapshot.title = "Café — listener's plan"
        snapshot.chapterTitle = "Try these (about ten minutes)"
        snapshot.currentPlaybackProgressPercent = 22
        snapshot.sourceProgressPercent = 75
        let date = Date(timeIntervalSince1970: 1_000)
        let context = RecordingPresentationContext(snapshot: snapshot, startedAt: date)
        XCTAssertEqual(context.itemTitle, snapshot.title)
        XCTAssertEqual(context.locationTitle, snapshot.chapterTitle)
        XCTAssertEqual(context.progressPercent, 22)
        XCTAssertEqual(context.startedAt, date)
    }

    func testMissingSessionLabelsUseNeutralFallbacks() {
        for title in [nil, ""] as [String?] {
            var snapshot = SessionSnapshot()
            snapshot.title = title
            let context = RecordingPresentationContext(snapshot: snapshot, startedAt: Date())
            XCTAssertEqual(context.itemTitle, "Current item")
            XCTAssertEqual(context.locationTitle, "Current listening position")
            XCTAssertEqual(context.progressPercent, 0)
        }
    }

    /// #1527: browsing B must not relabel a Margin captured on A, or give B that Margin.
    func testBrowsingAnotherItemKeepsRecordingPresentationAndSavedMarginOnPlayingSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        let a = Item(id: "a", title: "Phone test plan", mediaType: "text",
                     text: String(repeating: "Try these steps. ", count: 20), externalReference: nil, status: "ready")
        let b = Item(id: "b", title: "X post", mediaType: "text",
                     text: "A different source.", externalReference: nil, status: "ready")
        try store.saveItem(a)
        try store.saveItem(b)
        let bSession = Session(id: "session-b", itemId: b.id, status: "in_progress", phase: .itemPlayback,
                               currentTargetType: .itemTextTTS, currentTargetId: b.id,
                               position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(bSession)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
            "sync": ["canonical_persistence"], "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]), repository: store, audio: PresentationPlayer())
        let playing = try engine.startSession(itemId: a.id)
        let sessionID = try XCTUnwrap(playing.sessionId)
        let selectedItem = try store.loadItem(id: b.id) // A keeps playing while B's detail is read.
        XCTAssertEqual(selectedItem.id, b.id)
        XCTAssertEqual(engine.snapshot, playing, "reading B does not replace A's session")
        let date = Date(timeIntervalSince1970: 1_000)
        let requested = RecordingPresentationContext(snapshot: playing, startedAt: date)
        let recording = try engine.beginInterjection()
        let started = RecordingPresentationContext(snapshot: recording, startedAt: date)
        for context in [requested, started] {
            XCTAssertEqual(context.itemTitle, a.title)
            XCTAssertEqual(context.locationTitle, playing.chapterTitle)
            XCTAssertEqual(context.progressPercent, recording.currentPlaybackProgressPercent)
            XCTAssertGreaterThan(context.progressPercent, 0, "exercise a saved position within the item")
            XCTAssertEqual(context.startedAt, date)
        }
        _ = try engine.finishInterjection(audioRef: "interjections/test.m4a")
        let saved = try XCTUnwrap(store.loadInterjections(sessionId: sessionID).first)
        XCTAssertEqual(saved.itemId, a.id)
        XCTAssertEqual(saved.sessionId, sessionID)
        XCTAssertTrue(try store.loadInterjections(sessionId: bSession.id).isEmpty)
        let rows = try MarginCollection.build(items: store.listItems(), sessions: store.loadSessions(),
            loadInterjections: { try store.loadInterjections(sessionId: $0) },
            loadImportedLayers: { [] }, loadImportedInterjections: { _ in [] }).privateRows
        XCTAssertEqual(rows.map(\.interjection.id), [saved.id])
        XCTAssertEqual(rows.map(\.itemTitle), [a.title])
        XCTAssertFalse(rows.contains { MarginCollectionQuery(itemID: b.id).includes(itemID: $0.interjection.itemId) })
    }
}

private final class PresentationPlayer: AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func pause() throws {}
    func currentCharOffset() -> Int? { 64 }
}
