import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #3661: marking a spoken note complete saves it to the folder the listener chose, through the same destinations and
/// folder access as the Margin notes. A real note on disk, a real folder and bookmark, the real writer and journal.
@MainActor
final class SpokenNoteFolderSaveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A note with one take (so its audio is copied, not re-encoded) and one sentence, on disk where the app keeps notes.
    private func writeNote(id: String = "note-1") throws {
        let store = try XCTUnwrap(SpokenNoteStarter.store(noteId: id, in: root))
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
        try Data("take-one-audio".utf8).write(to: store.folderURL.appendingPathComponent("take-1.m4a"))
        var note = SpokenNote(id: id)
        note.appendTake(SpokenNoteTake(
            id: "take-1", audioFileName: "take-1.m4a", durationMs: 4000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: [SpokenNoteSentence(text: "Call the printer.", startMs: 0, endMs: 900)]))
        try store.save(note)
    }

    private func makeCoordinator(_ destinations: [MarginOutputDestination]) throws -> MarginOutputCoordinator {
        let destinationStore = MarginOutputDestinationStore(fileURL: root.appendingPathComponent("destinations.json"))
        try destinationStore.save(destinations)
        let journal = root.appendingPathComponent("journal.json")
        return MarginOutputCoordinator(
            store: { nil }, isRecording: { false }, destinationStore: destinationStore,
            legacy: { MarginOutputMigration.LegacySettings(bookmark: nil, destinationID: nil, isEnabled: false) },
            folders: .live, journalURL: { journal })
    }

    private func destination(_ folder: URL, enabled: Bool = true) throws -> MarginOutputDestination {
        MarginOutputDestination(id: "dest", name: "Vault", bookmark: try MarginOutputCoordinator.FolderAccess.live.makeBookmark(folder), isEnabled: enabled)
    }

    func testNoFolderAtAllSaysSoAndChangesNothing() async throws {
        try writeNote()
        let coordinator = try makeCoordinator([])
        let outcome = await coordinator.saveSpokenNote(noteId: "note-1", title: "Trip ideas", applicationSupport: root)
        XCTAssertEqual(outcome, .noFolder)
        XCTAssertTrue(outcome.needsFolderChoice)
    }

    func testAPausedFolderIsNotWrittenTo() async throws {
        try writeNote()
        let vault = try folder("Vault")
        let coordinator = try makeCoordinator([try destination(vault, enabled: false)])
        let outcome = await coordinator.saveSpokenNote(noteId: "note-1", title: "Trip ideas", applicationSupport: root)
        XCTAssertEqual(outcome, .folderPaused)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [])
    }

    func testCompletingSavesTheAudioAndTranscriptOnceAndShowsItOnTheRow() async throws {
        try writeNote()
        let vault = try folder("Vault")
        let coordinator = try makeCoordinator([try destination(vault)])

        let first = await coordinator.saveSpokenNote(noteId: "note-1", title: "Trip ideas", applicationSupport: root)
        XCTAssertEqual(first, .delivered([.init(folderName: "Vault", state: .saved)], leftOut: ""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path).sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Trip ideas.txt"), encoding: .utf8), "Call the printer.")
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("Trip ideas.m4a")), Data("take-one-audio".utf8))

        // The second tap, and a retitled note, add nothing.
        let second = await coordinator.saveSpokenNote(noteId: "note-1", title: "Printer errand", applicationSupport: root)
        XCTAssertEqual(second, .delivered([.init(folderName: "Vault", state: .upToDate)], leftOut: ""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path).sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])

        // The row's "Exported" comes from the journal, and survives a relaunch (a new coordinator over the same files).
        XCTAssertEqual(coordinator.spokenNotes.savedFolders(forNoteId: "note-1"), ["Vault"])
        let relaunched = try makeCoordinator([try destination(vault)])
        await relaunched.spokenNotes.reload(journalURL: try relaunched.spokenNoteJournalURL())
        XCTAssertEqual(relaunched.spokenNotes.savedFolders(forNoteId: "note-1"), ["Vault"])
        XCTAssertEqual(relaunched.spokenNotes.savedFolders(forNoteId: "another"), [])
    }

    func testAFolderThatIsGoneReportsAndTheNoteIsUntouched() async throws {
        try writeNote()
        let vault = try folder("Vault")
        let coordinator = try makeCoordinator([try destination(vault)])
        try FileManager.default.removeItem(at: vault)

        let outcome = await coordinator.saveSpokenNote(noteId: "note-1", title: "Trip ideas", applicationSupport: root)

        XCTAssertEqual(outcome, .delivered([.init(folderName: "Vault", state: .folderUnavailable)], leftOut: ""))
        XCTAssertTrue(outcome.needsFolderChoice)
        XCTAssertTrue(outcome.isProblem)
        XCTAssertTrue(coordinator.rows.first?.needsAccess == true, "Settings shows the same Needs folder access it shows for Margin notes")
        let store = try XCTUnwrap(SpokenNoteStarter.store(noteId: "note-1", in: root))
        XCTAssertEqual(store.peek()?.takes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folderURL.appendingPathComponent("take-1.m4a").path))
    }

    func testANoteWithNothingOnThisPhoneSaysSo() async throws {
        let vault = try folder("Vault")
        let coordinator = try makeCoordinator([try destination(vault)])
        let outcome = await coordinator.saveSpokenNote(noteId: "missing", title: "Gone", applicationSupport: root)
        XCTAssertEqual(outcome, .notOnThisPhone)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [])
    }
}
