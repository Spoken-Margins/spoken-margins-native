import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #4780: the words a spoken note shows on Now are read from the note itself, off the main actor, and only read.
@MainActor
final class SpokenNoteNowTranscriptTests: XCTestCase {
    private var support: URL!
    // One id per test: the loader keeps its last result per note id for the whole process, so a shared id lets a
    // later test start from an earlier test's cached result.
    private let noteId = "now-note-\(UUID().uuidString)"

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("now-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private var store: SpokenNoteStore { SpokenNoteStarter.store(noteId: noteId, in: support)! }
    private var reference: String { SpokenNoteItem.reference(forNoteId: noteId) }

    private func take(_ id: String, _ sentences: [String]) -> SpokenNoteTake {
        SpokenNoteTake(id: id, audioFileName: "take-\(id).m4a", durationMs: 60_000, createdAt: Date(timeIntervalSince1970: 0),
                       sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 5_000, endMs: $0 * 5_000 + 4_000) })
    }

    /// Waits on the loader's state, with a deadline that is only a ceiling.
    private func wait(_ loader: SpokenNoteNowTranscript, until condition: (SpokenNoteNowTranscript) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !condition(loader) { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testASpokenNoteLoadsItsWordsForNow() async throws {
        let note = SpokenNote(id: noteId, takes: [
            take("a", ["so I was thinking about it", "and then the other part"]), take("b", ["one more without a stop"])
        ])
        try store.save(note)
        let loader = SpokenNoteNowTranscript()
        loader.load(externalReference: reference) { support }
        try await wait(loader) { $0.availability != .loading }
        XCTAssertEqual(loader.availability, .ready)
        XCTAssertEqual(loader.words?.rows.count, 3, "one row per sentence of the note")
        XCTAssertEqual(SpokenNoteNowPassage.NowLayout.choose(isNativeAudio: true, isSpokenNote: true, availability: loader.availability), .noteWords)
    }

    func testANoteWithoutAFileReadsAsNoWordsAndIsNotMoved() async throws {
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        let loader = SpokenNoteNowTranscript()
        loader.load(externalReference: reference) { support }
        try await wait(loader) { $0.availability != .loading }
        XCTAssertEqual(loader.availability, .noWords)
        XCTAssertNil(loader.words)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path), "an unreadable note is never moved aside from Now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.setAsideURL.path))
    }

    func testANoteChangeReloadsAndMovesTheRevisionOnce() async throws {
        try store.save(SpokenNote(id: noteId, takes: [take("a", ["first words here"]), take("b", [])]))
        let loader = SpokenNoteNowTranscript()
        loader.load(externalReference: reference) { support }
        try await wait(loader) { $0.availability != .loading }
        XCTAssertEqual(loader.availability, .partial(takesWithoutWords: 1))
        let revision = loader.revision

        // A read with nothing new keeps the revision, so the scene keeps its place.
        loader.load(externalReference: reference) { support }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(loader.revision, revision)

        var note = store.peek()!
        note.setTranscript([SpokenNoteSentence(text: "the second take's words", startMs: 0, endMs: 2_000)], forTake: "b")
        try store.save(note)
        NotificationCenter.default.post(name: .spokenNoteChanged, object: nil)
        loader.load(externalReference: reference) { support }
        try await wait(loader) { $0.availability == .ready }
        XCTAssertEqual(loader.availability, .ready)
        XCTAssertEqual(loader.revision, revision + 1)
    }

    func testAnItemThatIsNoNoteClearsTheWords() async throws {
        let loader = SpokenNoteNowTranscript()
        loader.load(externalReference: "https://example.com/article") { support }
        XCTAssertEqual(loader.availability, .loading)
        XCTAssertNil(loader.words)
    }
}
