import Foundation
import XCTest
@testable import SessionKit

/// The delivery of Margin and item notes into the listener's notes folder (moved from the app target, #318).
final class AutomaticMarginWriterTests: XCTestCase {
    func testAutomaticDeliveryRetriesWithoutDuplicatesAndPreservesExternalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        let writer = AutomaticMarginWriter(journalURL: journal)
        let note = AutomaticMarginWriter.Note(id: "session-a:margin-1", markdown: "# Thought\n\nOriginal")
        _ = try await writer.deliver([note], to: folder, destinationID: "vault")
        let restarted = AutomaticMarginWriter(journalURL: journal)
        _ = try await restarted.deliver([note], to: folder, destinationID: "vault")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        _ = try await restarted.deliver([.init(id: note.id, markdown: "Updated transcript")], to: folder, destinationID: "vault")
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "Updated transcript")
        try Data("My Obsidian edit".utf8).write(to: files[0])
        // #581: the edit is kept and counted, not reported as a failure.
        let summary = try await restarted.deliver([.init(id: note.id, markdown: "Another transcript"), .init(id: "unaffected", markdown: "Another independent Margin")], to: folder, destinationID: "vault")
        XCTAssertEqual(summary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1))
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "My Obsidian edit")
        let delivered = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(delivered.count, 2, "One conflict must not prevent independent delivery")
    }

    /// #587: an item note asks for its own file name and keeps the first one when the item is renamed, so completing
    /// again rewrites the same file. A Margin note still gets `Margin-<digest>.md`, and a journal from an earlier build
    /// (no file name in its entries) still decodes.
    func testItemNotesKeepTheirFirstFileNameAndMarginNotesAreNamedAsBefore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("journal.json")
        try Data(#"{"old:entry": {"previous": null, "intended": "abc"}}"#.utf8).write(to: journal)
        let writer = AutomaticMarginWriter(journalURL: journal)
        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        }

        _ = try await writer.deliver([
            .init(id: "item:item-1", markdown: "First", fileName: "Old title — Margins 1a2b3c.md"),
            .init(id: "session-a:margin-1", markdown: "A Margin"),
        ], to: folder, destinationID: "vault")
        XCTAssertEqual(try names(), ["Margin-\(ListeningEdition.digest("session-a:margin-1")).md", "Old title — Margins 1a2b3c.md"])

        // The item was renamed and completed again, in a new app launch.
        let restarted = AutomaticMarginWriter(journalURL: journal)
        _ = try await restarted.deliver([
            .init(id: "item:item-1", markdown: "Second", fileName: "New title — Margins 1a2b3c.md"),
        ], to: folder, destinationID: "vault")
        XCTAssertEqual(try names().count, 2, "no second copy under the new title")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Old title — Margins 1a2b3c.md"), encoding: .utf8), "Second")
    }

    /// Build 29 wrote Margin notes without a properties block (#491). The writer must rewrite its
    /// own unedited notes once to gain the block, and still never overwrite a note edited outside the app.
    func testMarginNotesGainPropertiesOnceWithoutOverwritingEditedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func note(_ marginID: String) throws -> String {
            let json = """
            {"schemaVersion": "spoken-margins.export.v1", "item": {"id": "item-a", "title": "Episode: \\"one\\"", "externalReference": "https://example.com/1", "includedFullText": false},
             "session": {"id": "session-a", "status": "in_progress", "completionPercent": 10},
             "turns": [], "timeline": [],
             "interjections": [{"id": "\(marginID)", "sessionId": "session-a", "targetType": "item", "targetId": "item-a",
               "roughPercent": 10, "anchorBefore": "Before.", "anchorAfter": "After.", "mediaTimeMs": 5000,
               "transcriptionStatus": "transcribed", "transcript": "A thought.", "audioPath": null}]}
            """
            let export = try JSONDecoder().decode(SessionExport.self, from: Data(json.utf8))
            return SessionExportMarkdownRenderer.renderMargin(export, createdAt: Date(timeIntervalSince1970: 1_777_000_000))
        }
        let current = [AutomaticMarginWriter.Note(id: "session-a:m1", markdown: try note("m1")),
                       AutomaticMarginWriter.Note(id: "session-a:m2", markdown: try note("m2"))]
        // The Build 29 note is the same body without the properties block.
        let build29 = try current.map { note in
            let parts = note.markdown.components(separatedBy: "\n---\n\n")
            XCTAssertTrue(note.markdown.hasPrefix("---\n"))
            return AutomaticMarginWriter.Note(id: note.id, markdown: try XCTUnwrap(parts.count == 2 ? parts[1] : nil))
        }
        let journal = root.appendingPathComponent("journal.json")
        _ = try await AutomaticMarginWriter(journalURL: journal).deliver(build29, to: folder, destinationID: "vault")
        func file(_ id: String) -> URL { folder.appendingPathComponent("Margin-\(ListeningEdition.digest(id)).md") }
        try Data("My Obsidian edit".utf8).write(to: file("session-a:m2"))

        let upgraded = AutomaticMarginWriter(journalURL: journal)
        let summary = try await upgraded.deliver(current, to: folder, destinationID: "vault")
        XCTAssertEqual(summary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1), "The edited note is kept, not overwritten")
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try String(contentsOf: file("session-a:m2"), encoding: .utf8), "My Obsidian edit")

        // Once: a second pass leaves the rewritten note's bytes and date alone.
        let written = try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date
        _ = try? await upgraded.deliver([current[0]], to: folder, destinationID: "vault")
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date, written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testDeliveryReportsWhichNotesTheListenerEditedAndKeepsThemAcrossPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AutomaticMarginWriter(journalURL: root.appendingPathComponent("journal.json"))
        let notes = [AutomaticMarginWriter.Note(id: "a", markdown: "A one"), .init(id: "b", markdown: "B one")]
        _ = try await writer.deliver(notes, to: folder, destinationID: "vault")
        try Data("edited".utf8).write(to: folder.appendingPathComponent("Margin-\(ListeningEdition.digest("b")).md"))

        let changed = [AutomaticMarginWriter.Note(id: "a", markdown: "A two"), .init(id: "b", markdown: "B two")]
        let result = try await writer.deliverReportingKeptEdits(changed, to: folder, destinationID: "vault")
        XCTAssertEqual(result.summary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1))
        XCTAssertEqual(result.keptEditIDs, ["b"])
        // A pass over only the first note still leaves the edited one alone, and reports none.
        let partial = try await writer.deliverReportingKeptEdits([changed[0]], to: folder, destinationID: "vault")
        XCTAssertEqual(partial.summary, MarginNoteDelivery.Summary(saved: 1))
        XCTAssertTrue(partial.keptEditIDs.isEmpty)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Margin-\(ListeningEdition.digest("b")).md"), encoding: .utf8), "edited")
    }

    func testANoteThatCannotBeWrittenIsReportedAsAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notAFolder = root.appendingPathComponent("vault")
        try Data("a file where the folder should be".utf8).write(to: notAFolder)
        let writer = AutomaticMarginWriter(journalURL: root.appendingPathComponent("journal.json"))

        do {
            _ = try await writer.deliver([.init(id: "a", markdown: "A")], to: notAFolder, destinationID: "vault")
            XCTFail("a note that can't be written must be reported")
        } catch let error as EditionError {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testAJournalThatCannotBeReadFailsTheWholePassBeforeAnyNoteIsWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("journal.json")
        try Data("not json".utf8).write(to: journal)
        let writer = AutomaticMarginWriter(journalURL: journal)

        do {
            _ = try await writer.deliver([.init(id: "a", markdown: "A")], to: folder, destinationID: "vault")
            XCTFail("an unreadable journal must not be overwritten silently")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "not json")
    }
}
