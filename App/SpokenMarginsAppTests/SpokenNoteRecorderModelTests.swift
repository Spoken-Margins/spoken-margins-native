import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #3108: a spoken note opened from its Library row shows the takes it already has, and says so plainly when its
/// files are not on this phone. Real temporary folders; the microphone and speech recognizer are never started
/// (the note opened has a transcript already, so nothing is asked of the recognizer).
@MainActor
final class SpokenNoteRecorderModelTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    private struct NoWriter: SpokenNoteItemWriting {
        func write(_ item: Item, isFirstSave: Bool) throws {}
    }

    private func environment() -> SpokenNoteRecorderEnvironment {
        SpokenNoteRecorderEnvironment(
            applicationSupport: support, itemWriter: NoWriter(),
            requestMicrophone: { false }, prepareToRecord: {}, libraryChanged: {}, beginBackgroundWork: { _ in {} }
        )
    }

    private func waitForSnapshot(_ model: SpokenNoteRecorderModel) async {
        for _ in 0..<40 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testAReopenedNoteShowsItsTakesAndKnowsItsFolder() async throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try Data([1]).write(to: started.store.folderURL.appendingPathComponent("take-a.m4a"))
        try SpokenNoteIntake.addRecordedTake(audioFileName: "take-a.m4a", durationMs: 4_000, to: started.store, now: Date(timeIntervalSince1970: 2), takeId: "a")
        var note = started.store.load()
        note.setTranscript([SpokenNoteSentence(text: "Call the plumber.", startMs: 0, endMs: 1_200)], forTake: "a")
        try started.store.save(note)

        let model = SpokenNoteRecorderModel()
        model.attach(environment(), opening: SpokenNoteOpening(noteId: "n1", title: "Plumber call"))
        await waitForSnapshot(model)

        XCTAssertEqual(model.snapshot?.note.takes.map(\.id), ["a"])
        XCTAssertEqual(model.snapshot?.note.takes.first?.sentences.map(\.text), ["Call the plumber."])
        XCTAssertEqual(model.noteFolder?.lastPathComponent, "n1")
        XCTAssertNil(model.message)
        XCTAssertEqual(model.phase, .idle)
        await model.finish()
    }

    func testANoteWhoseFilesAreMissingSaysSoAndMakesNothing() {
        let model = SpokenNoteRecorderModel()
        model.attach(environment(), opening: SpokenNoteOpening(noteId: "gone", title: "Old note"))

        XCTAssertEqual(model.message, "This note's recordings aren't on this phone.")
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpokenNoteStarter.notesRoot(in: support).appendingPathComponent("gone").path))
    }

    func testOpeningMakesNoFolderForANewNoteUntilRecordIsTapped() {
        let model = SpokenNoteRecorderModel()
        model.attach(environment())
        let notes = (try? FileManager.default.contentsOfDirectory(atPath: SpokenNoteStarter.notesRoot(in: support).path)) ?? []
        XCTAssertTrue(notes.isEmpty)
        XCTAssertNil(model.noteFolder)
    }
}
