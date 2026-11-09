import UIKit
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #3660: Export's "Text only", from a door's request to what the share sheet is given. A real note on disk and the real
/// model; the owner's failed check was that a listener had no way to reach text on its own.
@MainActor
final class SpokenNoteTextExportFlowTests: XCTestCase {
    private var root: URL!
    private let model = SpokenNoteExportModel()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        model.abandon()
        try? FileManager.default.removeItem(at: root)
    }

    /// A note on disk with one take per entry in `takes`, each take the sentences given.
    private func writeNote(takes: [[String]]) throws -> SpokenNote {
        let store = try XCTUnwrap(SpokenNoteStarter.store(noteId: "note-1", in: root))
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
        var note = SpokenNote(id: "note-1")
        for (index, sentences) in takes.enumerated() {
            try Data("audio".utf8).write(to: store.folderURL.appendingPathComponent("take-\(index).m4a"))
            note.appendTake(SpokenNoteTake(
                id: "take-\(index)", audioFileName: "take-\(index).m4a", durationMs: 4000, createdAt: Date(timeIntervalSince1970: 0),
                sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1000, endMs: $0 * 1000 + 900) }))
        }
        try store.save(note)
        return note
    }

    private func settle(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), "the export never reached the expected state")
    }

    /// A row's Export asks first, and nothing is made until the listener picks.
    func testARowsExportAsksAndTextOnlyReachesTheShareSheet() async throws {
        _ = try writeNote(takes: [["First."], ["Second."]])

        model.export(noteId: "note-1", title: "Shop plans", applicationSupport: root)
        let request = try XCTUnwrap(model.choosing, "the door has to ask")
        XCTAssertNil(model.text)
        XCTAssertNil(model.files)

        model.choose(.textOnly, for: request)
        XCTAssertNil(model.choosing)
        try await settle { model.text != nil }

        let exported = try XCTUnwrap(model.text)
        XCTAssertEqual(exported.text, "Shop plans\n\nFirst.\n\nSecond.")
        XCTAssertNil(model.files, "text only makes no audio file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exported.folderURL.path), ["Shop plans.txt"])
    }

    func testTheNoteScreensExportReachesTheSameChoice() async throws {
        let note = try writeNote(takes: [["On screen."]])
        let store = try XCTUnwrap(SpokenNoteStarter.store(noteId: "note-1", in: root))

        model.export(note: note, noteFolder: store.folderURL, title: "Open note")
        model.choose(.textOnly, for: try XCTUnwrap(model.choosing))
        try await settle { model.text != nil }

        XCTAssertEqual(model.text?.text, "Open note\n\nOn screen.")
    }

    func testAudioAndTextStillSharesBoth() async throws {
        _ = try writeNote(takes: [["Words."]])
        model.export(noteId: "note-1", title: "Both", applicationSupport: root)
        model.choose(.audioAndText, for: try XCTUnwrap(model.choosing))
        try await settle { model.files != nil }

        XCTAssertEqual(model.files?.shareURLs.map(\.lastPathComponent), ["Both.m4a", "Both.txt"])
        XCTAssertNil(model.text)
    }

    func testANoteWithNoWordsSaysSoAndOffersItsAudio() async throws {
        _ = try writeNote(takes: [[]])
        model.export(noteId: "note-1", title: "Silent", applicationSupport: root)
        model.choose(.textOnly, for: try XCTUnwrap(model.choosing))
        try await settle { model.noWords != nil }
        XCTAssertNil(model.text, "never an empty share")
        XCTAssertNil(model.message, "no words is an offer, not a failure")

        model.choose(.audioAndText, for: try XCTUnwrap(model.noWords))
        XCTAssertNil(model.noWords)
        // The take has no words, so its audio comes with the usual question about what is left out.
        try await settle { model.partial != nil }
        XCTAssertEqual(model.partial?.shareURLs.map(\.lastPathComponent), ["Silent.m4a"])
    }

    func testATakeWithNoWordsIsToldBeforeTheTextIsShared() async throws {
        _ = try writeNote(takes: [["Heard."], []])
        model.export(noteId: "note-1", title: "Half", applicationSupport: root)
        model.choose(.textOnly, for: try XCTUnwrap(model.choosing))
        try await settle { model.partialText != nil }
        XCTAssertEqual(model.partialQuestion, "1 take has no words written down yet, so the text leaves it out.")
        XCTAssertNil(model.text)

        model.resolvePartial(share: true)
        try await settle { model.text != nil }
        XCTAssertNil(model.partialQuestion)
    }

    func testClosingTheShareSheetRemovesTheTemporaryCopy() async throws {
        _ = try writeNote(takes: [["Words."]])
        model.export(noteId: "note-1", title: "T", applicationSupport: root)
        model.choose(.textOnly, for: try XCTUnwrap(model.choosing))
        try await settle { model.text != nil }
        let folder = try XCTUnwrap(model.text?.folderURL)

        model.text = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Notes and Copy must get a real String, and Files a real file with the note's name. Neither gets a duplicate.
    func testShareItemsGiveEachDestinationARealStringOrFile() throws {
        var note = SpokenNote(id: "n")
        note.appendTake(SpokenNoteTake(
            id: "a", audioFileName: "a.m4a", durationMs: 1000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: [SpokenNoteSentence(text: "Words.", startMs: 0, endMs: 900)]))
        let exported = try SpokenNoteExport.prepareText(note: note, title: "Named", into: root)
        let items = SpokenNoteTextShareItem.items(for: exported)
        XCTAssertEqual(items.count, 2)

        for activity in [UIActivity.ActivityType.copyToPasteboard.rawValue, UIActivity.ActivityType.message.rawValue, "com.apple.mobilenotes.SharingExtension"] {
            let given = items.compactMap { $0.item(forActivity: activity) }
            XCTAssertEqual(given.count, 1, activity)
            XCTAssertEqual(given.first as? String, "Named\n\nWords.", activity)
        }

        let forFiles = items.compactMap { $0.item(forActivity: "com.apple.DocumentManagerUICore.SaveToFiles") }
        XCTAssertEqual(forFiles.count, 1)
        XCTAssertEqual((forFiles.first as? URL)?.lastPathComponent, "Named.txt")

        let forUnknown = items.compactMap { $0.item(forActivity: "com.example.unknown") }
        XCTAssertEqual(forUnknown.count, 2, "an unknown destination is offered both forms, never neither")
    }
}
