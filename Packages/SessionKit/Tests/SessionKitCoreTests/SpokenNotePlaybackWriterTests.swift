import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3662: the database gives a spoken note's Library item its audio and timeline, on a real SQLite file. It changes only
/// what playback needs; a renamed row keeps its name, and a trashed or missing row is not brought back.
final class SpokenNotePlaybackWriterTests: XCTestCase {
    private var path = ""
    private let audio = URL(fileURLWithPath: "/tmp/SpokenNotes/n/whole-note.m4a")

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "spoken-note-playback-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func timeline(_ words: String...) -> MediaTimeline {
        var chars = 0
        let segments = words.enumerated().map { index, word -> MediaTimelineSegment in
            defer { chars += word.count + 1 }
            return MediaTimelineSegment(id: "s\(index)", startMs: index * 1000, endMs: index * 1000 + 900,
                                        startChar: chars, endChar: chars + word.count, text: word)
        }
        return MediaTimeline(segments: segments, chapters: [], durationMs: words.count * 1000)
    }

    private func savedNote(_ store: SQLiteSessionStore, title: String? = nil) throws -> Item {
        let note = SpokenNote(id: "n")
        let item = SpokenNoteItem.makeItem(note: note, title: title, createdAt: Date())
        try store.saveItem(item)
        return item
    }

    func testTheRowGetsItsAudioItsTimelineAndTheTextTheOffsetsCountIn() throws {
        let store = try SQLiteSessionStore(path: path)
        let item = try savedNote(store, title: "My own name")
        let written = try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 2000, timeline: timeline("One.", "Two."), text: "One. Two.")
        XCTAssertTrue(written)

        let row = try store.loadItem(id: item.id)
        XCTAssertEqual(row.title, "My own name", "a rename is kept")
        XCTAssertEqual(row.mediaType, SpokenNoteItem.mediaType)
        XCTAssertEqual(row.externalReference, item.externalReference)
        XCTAssertEqual(row.text, "One. Two.")
        XCTAssertEqual(row.media?.sourceType, .nativeMediaFile)
        XCTAssertEqual(row.media?.url, audio.absoluteString)
        XCTAssertEqual(row.media?.durationMs, 2000)
        XCTAssertEqual(row.transcriptId, "transcript-\(item.id)")
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: item.id)?.timeline, timeline("One.", "Two."))
    }

    func testPlayingAgainWithNothingNewChangesNothingAndANewTakeReplacesTheTimeline() throws {
        let store = try SQLiteSessionStore(path: path)
        let item = try savedNote(store)
        XCTAssertTrue(try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 1000, timeline: timeline("One."), text: "One."))
        let first = try store.loadTranscriptTimeline(itemId: item.id)
        XCTAssertTrue(try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 1000, timeline: timeline("One."), text: "One."))
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: item.id)?.createdAt, first?.createdAt, "an unchanged timeline is not saved again")

        XCTAssertTrue(try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 2000, timeline: timeline("One.", "Two."), text: "One. Two."))
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: item.id)?.timeline, timeline("One.", "Two."))
        XCTAssertEqual(try store.loadItem(id: item.id).media?.durationMs, 2000)
    }

    func testATrashedRowIsNotBroughtBackOrChanged() throws {
        let store = try SQLiteSessionStore(path: path)
        var item = try savedNote(store)
        item.deletedAt = Date()
        try store.saveItem(item)
        XCTAssertFalse(try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 1000, timeline: timeline("One."), text: "One."))
        let row = try store.loadItem(id: item.id)
        XCTAssertNotNil(row.deletedAt)
        XCTAssertNil(row.media)
        XCTAssertNil(try store.loadTranscriptTimeline(itemId: item.id))
    }

    func testARowThatWasNeverSavedIsNotMade() throws {
        let store = try SQLiteSessionStore(path: path)
        XCTAssertFalse(try store.attachPlayback(itemId: "spoken-note-nobody", audioURL: audio, durationMs: 1, timeline: timeline("One."), text: "One."))
        XCTAssertNil(try? store.loadItem(id: "spoken-note-nobody"))
    }

    func testOnlyASpokenNoteRowIsChanged() throws {
        let store = try SQLiteSessionStore(path: path)
        let article = Item(id: "article-1", title: "An article", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")
        try store.saveItem(article)
        XCTAssertFalse(try store.attachPlayback(itemId: article.id, audioURL: audio, durationMs: 1, timeline: timeline("Words."), text: "Words."))
        XCTAssertNil(try store.loadItem(id: article.id).media)
    }

    func testAPreparedNoteIsNotQueuedForAnEpisodeMapOfItsOwn() throws {
        let store = try SQLiteSessionStore(path: path)
        let item = try savedNote(store)
        let control = Item(
            id: "audiobook-1", title: "A book", mediaType: "audiobook", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///book.m4a", durationMs: 1000))
        try store.saveItem(control)
        XCTAssertTrue(try store.attachPlayback(itemId: item.id, audioURL: audio, durationMs: 1000, timeline: timeline("One."), text: "One."))
        XCTAssertEqual(AutomaticEpisodeMapJobs.candidates(itemIds: [item.id, control.id], store: store), [control.id])
    }
}
