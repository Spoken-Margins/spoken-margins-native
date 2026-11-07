import XCTest
@testable import SessionKit

/// #3661: marking a spoken note complete puts its audio and transcript in the folder the listener chose, once. Real
/// temporary folders and a real journal file; nothing is faked at the file boundary.
final class SpokenNoteFolderExportTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var journalURL: URL { root.appendingPathComponent("journal.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-folder-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The files `SpokenNoteExport.prepare` would hand over: `<title>.m4a` and `<title>.txt` in a made-for-it folder.
    private func prepared(_ title: String, audio: String = "audio-1", text: String? = "Hello there.") throws -> SpokenNoteExportFiles {
        let made = root.appendingPathComponent("made-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let base = SpokenNoteExport.fileBaseName(forTitle: title)
        let audioURL = made.appendingPathComponent("\(base).m4a")
        try Data(audio.utf8).write(to: audioURL)
        var transcriptURL: URL?
        if let text {
            transcriptURL = made.appendingPathComponent("\(base).txt")
            try Data(text.utf8).write(to: transcriptURL!)
        }
        return SpokenNoteExportFiles(
            folderURL: made, audioURL: audioURL, transcriptURL: transcriptURL,
            missingAudioTakeCount: 0, takesWithoutTranscriptCount: 0)
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func deliver(
        _ files: SpokenNoteExportFiles, noteId: String = "note-1", signature: String = "t1", destination: String = "dest-1", to target: URL? = nil
    ) async throws -> SpokenNoteFolderWriter.Result {
        try await SpokenNoteFolderWriter(journalURL: journalURL).deliver(
            files, noteId: noteId, to: target ?? folder, destinationID: destination, destinationName: "Vault", audioSignature: signature)
    }

    func testMarkingCompleteWritesTheAudioAndTranscriptNamedByTheTitle() async throws {
        let result = try await deliver(try prepared("Trip ideas"))
        XCTAssertEqual(try listing(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(try read("Trip ideas.txt"), "Hello there.")
        XCTAssertEqual(try read("Trip ideas.m4a"), "audio-1")
        XCTAssertEqual(result.written.sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(SpokenNoteFolderJournal.savedFolderNames(from: journalURL, noteIds: ["note-1", "other"]), ["note-1": ["Vault"]])
    }

    func testASecondTapWritesNothingAndAddsNothing() async throws {
        _ = try await deliver(try prepared("Trip ideas"))
        let result = try await deliver(try prepared("Trip ideas"))
        XCTAssertEqual(try listing(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertTrue(result.written.isEmpty)
        XCTAssertEqual(result.upToDate.sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])
    }

    func testARetitleLaterRewritesTheSameFilesInsteadOfAddingCopies() async throws {
        _ = try await deliver(try prepared("Spoken note", text: "First."))
        let result = try await deliver(try prepared("Trip ideas", text: "First, then more."), signature: "t1")
        XCTAssertEqual(try listing(), ["Spoken note.m4a", "Spoken note.txt"], "the first name stays; no second copy")
        XCTAssertEqual(try read("Spoken note.txt"), "First, then more.", "the unedited transcript follows the note")
        XCTAssertEqual(result.written, ["Spoken note.txt"])
    }

    func testANewTakeRewritesTheAudioInPlace() async throws {
        _ = try await deliver(try prepared("Trip ideas", audio: "one"), signature: "t1")
        let result = try await deliver(try prepared("Trip ideas", audio: "one-and-two"), signature: "t1,t2")
        XCTAssertEqual(try listing(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(try read("Trip ideas.m4a"), "one-and-two")
        XCTAssertTrue(result.written.contains("Trip ideas.m4a"))
    }

    func testAFileTheListenerEditedIsLeftAlone() async throws {
        _ = try await deliver(try prepared("Trip ideas", text: "Original."))
        try Data("My edit.".utf8).write(to: folder.appendingPathComponent("Trip ideas.txt"))
        let result = try await deliver(try prepared("Trip ideas", text: "Original, plus a take."), signature: "t1,t2")
        XCTAssertEqual(try read("Trip ideas.txt"), "My edit.")
        XCTAssertEqual(result.keptEdits, ["Trip ideas.txt"])
    }

    func testAFileOfTheListenersWithTheSameNameIsNeverOverwritten() async throws {
        try Data("Mine.".utf8).write(to: folder.appendingPathComponent("Trip ideas.txt"))
        try Data("Mine too.".utf8).write(to: folder.appendingPathComponent("Trip ideas.m4a"))
        let result = try await deliver(try prepared("Trip ideas"))
        XCTAssertEqual(try read("Trip ideas.txt"), "Mine.")
        XCTAssertEqual(try read("Trip ideas.m4a"), "Mine too.")
        XCTAssertEqual(try listing(), ["Trip ideas 2.m4a", "Trip ideas 2.txt", "Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(result.baseName, "Trip ideas 2")
        // And it stays "Trip ideas 2" the next time.
        let again = try await deliver(try prepared("Trip ideas"))
        XCTAssertEqual(again.baseName, "Trip ideas 2")
        XCTAssertEqual(try listing().count, 4)
    }

    func testTwoNotesWithOneTitleDoNotTakeEachOthersFiles() async throws {
        _ = try await deliver(try prepared("Spoken note", text: "A."), noteId: "a")
        _ = try await deliver(try prepared("Spoken note", text: "B."), noteId: "b")
        XCTAssertEqual(try read("Spoken note.txt"), "A.")
        XCTAssertEqual(try read("Spoken note 2.txt"), "B.")
    }

    func testAFileTheListenerDeletedIsWrittenAgain() async throws {
        _ = try await deliver(try prepared("Trip ideas"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Trip ideas.txt"))
        let result = try await deliver(try prepared("Trip ideas"))
        XCTAssertEqual(try listing(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(result.written, ["Trip ideas.txt"])
    }

    func testAMissingFolderReportsAndShowsNothingAsSaved() async throws {
        let gone = root.appendingPathComponent("Gone", isDirectory: true)
        do {
            _ = try await deliver(try prepared("Trip ideas"), to: gone)
            XCTFail("a folder that is not there must report")
        } catch let error as SpokenNoteFolderWriter.WriteError {
            guard case .couldNotWrite = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "nothing is made in the listener's place")
        XCTAssertTrue(SpokenNoteFolderJournal.savedFolderNames(from: journalURL, noteIds: ["note-1"]).isEmpty)
        // The folder comes back: the same note is written, under the name it reserved.
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        _ = try await deliver(try prepared("Trip ideas"), to: gone)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gone.path).sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])
    }

    func testEachFolderKeepsItsOwnNames() async throws {
        let other = root.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await deliver(try prepared("Trip ideas"), destination: "d1")
        _ = try await deliver(try prepared("Trip ideas"), destination: "d2", to: other)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path).sorted(), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertEqual(try listing(), ["Trip ideas.m4a", "Trip ideas.txt"])
    }

    func testAnAudioOnlyNoteWritesNoTranscript() async throws {
        let result = try await deliver(try prepared("Quiet one", text: nil))
        XCTAssertEqual(try listing(), ["Quiet one.m4a"])
        XCTAssertEqual(result.written, ["Quiet one.m4a"])
    }

    func testNoPartialFileIsLeftBehind() async throws {
        _ = try await deliver(try prepared("Trip ideas"))
        XCTAssertFalse(try listing().contains { $0.hasSuffix(".partial") })
    }

    // MARK: wording

    func testTheLineSaysPlainlyWhatHappened() {
        XCTAssertEqual(
            SpokenNoteFolderOutcome.noFolder.line(title: "Trip ideas"),
            "No export folder is set, so “Trip ideas” wasn't saved to one. Choose a folder in Settings.")
        XCTAssertTrue(SpokenNoteFolderOutcome.noFolder.needsFolderChoice)
        XCTAssertTrue(SpokenNoteFolderOutcome.noFolder.isProblem)
        let saved = SpokenNoteFolderOutcome.delivered([.init(folderName: "Vault", state: .saved)], leftOut: "")
        XCTAssertEqual(saved.line(title: "Trip ideas"), "Saved “Trip ideas” to Vault.")
        XCTAssertFalse(saved.isProblem)
        XCTAssertFalse(saved.needsFolderChoice)
        let gone = SpokenNoteFolderOutcome.delivered([.init(folderName: "Vault", state: .folderUnavailable)], leftOut: "")
        XCTAssertTrue(gone.needsFolderChoice)
        XCTAssertTrue(gone.line(title: "T").contains("safe in your Library"))
        let partial = SpokenNoteFolderOutcome.delivered([.init(folderName: "Vault", state: .upToDate)], leftOut: "1 take has no words written down yet.")
        XCTAssertTrue(partial.line(title: "T").hasSuffix("1 take has no words written down yet."))
    }
}
