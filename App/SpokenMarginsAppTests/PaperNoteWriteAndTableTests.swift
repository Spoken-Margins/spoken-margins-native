import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #4340 PR 5 and PR 6 of the Design: Write it saves an answer at the chosen place without touching playback, Change answer
/// by writing moves the role, and the Paper notes table follows the Margins tab's scope.
@MainActor
final class PaperNoteWriteAndTableTests: XCTestCase {
    private func makeModel() throws -> (Gate1AppModel, SQLiteSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "paper-note-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        return (model, try SQLiteSessionStore(path: url.path), root)
    }

    private func answers(_ store: SQLiteSessionStore, session: String) throws -> [Interjection] {
        try store.loadInterjections(sessionId: session).filter { $0.paperRole != nil }
    }

    func testWriteItSavesAnswersAtTheirPlacesAndLeavesPlaybackAlone() async throws {
        let (model, store, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        // A saved place past the first sentence, so "Where you are" and "Start of the paper" are different places.
        var placed = try XCTUnwrap(store.loadSession(id: sessionId))
        placed.position = Position(charOffset: 20)
        try store.saveSession(placed)
        let before = try XCTUnwrap(store.loadSession(id: sessionId))
        let playingItem = model.selectedItem.id
        XCTAssertTrue(model.canWritePaperAnswer, "a started item can be written to")
        let context = try XCTUnwrap(await model.paperNoteWriteContext(document: nil))
        XCTAssertEqual(try context.character(for: .whereYouAre), 20)
        XCTAssertNotEqual(try context.character(for: .startOfPaper), 20)

        XCTAssertTrue(model.writePaperAnswer(draftId: "d1", role: .purpose, text: "We test sleep.", choice: .whereYouAre, context: context))
        XCTAssertTrue(model.writePaperAnswer(draftId: "d2", role: .keyFinding, text: "It halves.", choice: .startOfPaper, context: context))
        XCTAssertTrue(model.writePaperAnswer(draftId: "d2", role: .keyFinding, text: "It halves.", choice: .startOfPaper, context: context),
                      "a second Save of the same draft writes nothing more")

        let saved = try answers(store, session: sessionId)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first { $0.paperRole == .purpose }?.anchor.startChar, 20)
        XCTAssertEqual(saved.first { $0.paperRole == .keyFinding }?.anchor.startChar, try context.character(for: .startOfPaper))
        XCTAssertTrue(saved.allSatisfy { $0.captureKind == .written })

        let slots = model.paperNoteSlots(document: nil)
        let filled = slots.rows.compactMap { row -> PaperNoteRole? in
            if case .filled = row { return row.role }
            return nil
        }
        XCTAssertEqual(filled, [.purpose, .keyFinding], "the slots show the answers at once")

        let after = try XCTUnwrap(store.loadSession(id: sessionId))
        XCTAssertEqual(after.position, before.position, "the saved place is untouched")
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.selectedItem.id, playingItem)
    }

    func testChangeAnswerByWritingMovesTheRoleAndKeepsTheOldMargin() async throws {
        let (model, store, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let context = try XCTUnwrap(await model.paperNoteWriteContext(document: nil))
        XCTAssertTrue(model.writePaperAnswer(draftId: "old", role: .purpose, text: "First go.", choice: .startOfPaper, context: context))
        let old = try XCTUnwrap(try answers(store, session: sessionId).first)

        XCTAssertTrue(model.writePaperAnswer(
            draftId: "new", role: .purpose, text: "Second go.", choice: .startOfPaper, context: context, replacing: old))

        let all = try store.loadInterjections(sessionId: sessionId)
        XCTAssertNil(all.first { $0.id == old.id }?.paperRole, "the old answer gives up the role")
        XCTAssertEqual(all.first { $0.id == old.id }?.status, "active", "and stays a Margin")
        XCTAssertEqual(all.filter { $0.paperRole == .purpose }.map(\.displayText), ["Second go."])
    }

    func testThePaperNotesTableHasOneRowPerPaperInScope() async throws {
        let (model, store, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, title) in [("paper-a", "Alpha paper"), ("paper-b", "Beta paper")] {
            try store.saveItem(Item(id: id, title: title, mediaType: "pdf", text: "One sentence. Two sentences.", externalReference: nil, status: "ready"))
            let session = Session(
                id: "session-\(id)", itemId: id, createdAt: Date(), updatedAt: Date(), status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: id, position: Position(charOffset: 0), completionPercent: 10, playbackRate: 1)
            try store.saveSession(session)
            try store.saveInterjection(Interjection(
                id: "answer-\(id)", itemId: id, sessionId: session.id, targetType: .item, targetId: id, createdAt: Date(), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 12, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed", transcript: "Aim of \(title)",
                cleanedTranscript: nil, displayText: "Aim of \(title)", status: "active", captureKind: .written, paperRole: .purpose))
        }
        try model.refreshLibraryRows(store: store)
        await model.refreshMarginRowsAsync()
        XCTAssertTrue(model.hasPaperNotesInScope)

        func dataRows() async throws -> [String] {
            let url = try XCTUnwrap(await model.preparePaperNotesTableFileURL(format: .csv))
            defer { MarginMarkdownShare.discardShare(url) }
            XCTAssertEqual(url.lastPathComponent, "Paper notes.csv")
            let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
            return text.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }
        }
        let everything = try await dataRows()
        XCTAssertEqual(everything.count, 2)
        XCTAssertTrue(everything.contains { $0.hasPrefix("Alpha paper,") })

        let course = ItemCollection(id: "course", name: "Bio 101", itemIDs: ["paper-b"], createdAt: Date())
        try store.saveItemCollection(course)
        model.marginCollectionQuery = MarginCollectionQuery(collection: ItemCollectionScope(course))
        let scoped = try await dataRows()
        XCTAssertEqual(scoped.count, 1)
        XCTAssertTrue(scoped[0].hasPrefix("Beta paper,"))
    }
}
