import XCTest
import SessionKit
import AppIntents
@testable import SpokenMarginsApp

@MainActor
final class PKMWorkflowTests: XCTestCase {
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
        do {
            _ = try await restarted.deliver([.init(id: note.id, markdown: "Another transcript"), .init(id: "unaffected", markdown: "Another independent Margin")], to: folder, destinationID: "vault")
            XCTFail("An external edit must prevent overwrite")
        } catch { XCTAssertTrue(error.localizedDescription.contains("edited outside")) }
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "My Obsidian edit")
        let delivered = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(delivered.count, 2, "One conflict must not prevent independent delivery")
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
        do {
            _ = try await upgraded.deliver(current, to: folder, destinationID: "vault")
            XCTFail("The edited note must be reported, not overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("edited outside")) }
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try String(contentsOf: file("session-a:m2"), encoding: .utf8), "My Obsidian edit")

        // Once: a second pass leaves the rewritten note's bytes and date alone.
        let written = try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date
        _ = try? await upgraded.deliver([current[0]], to: folder, destinationID: "vault")
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date, written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testEditionImportPreservesActiveSessionAndRejectsSilentMapReplacement() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        model.importTitle = "Existing"; model.importText = "Keep the ongoing session."
        model.importTextItem(); model.pause()
        let activeSession = model.snapshot.sessionId
        var edition = ListeningEdition(title: "Imported", text: "An article " + UUID().uuidString,
            generator: "External model", overview: "Overview", scenes: [.init(title: "A", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        defer { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(edition.itemID)) }
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(model.snapshot.sessionId, activeSession)
        XCTAssertEqual(model.selectedItem.id, edition.itemID)
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(model.libraryItems.filter { $0.id == edition.itemID }.count, 1)
        edition.scenes[0].summary = "Changed"
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID)?.scenes[0].summary, "Summary")
        model.importListeningEditionData(try edition.encoded(), replaceMap: true)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID)?.scenes[0].summary, "Changed")
    }

    func testShortcutIntentImportsAndOpensEditionWithoutURLLaunch() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let edition = ListeningEdition(title: "Shortcut article", text: "Source " + UUID().uuidString,
            generator: "Ask ChatGPT", overview: "Overview", scenes: [.init(title: "One", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        defer { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(edition.itemID)) }
        let intent = ImportListeningEditionIntent()
        intent.file = IntentFile(data: try edition.encoded(), filename: "Listening Edition.json", type: .json)
        _ = try await intent.perform()
        XCTAssertEqual(model.selectedItem.id, edition.itemID)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID), edition)
        XCTAssertEqual(model.libraryItems.filter { $0.id == edition.itemID }.count, 1)
    }
}
