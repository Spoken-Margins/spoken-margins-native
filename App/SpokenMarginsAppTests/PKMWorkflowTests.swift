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
