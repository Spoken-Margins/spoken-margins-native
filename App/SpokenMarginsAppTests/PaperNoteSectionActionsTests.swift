import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #4340 PR 4: the Paper note section's taps reach the right Margin, including one of another session, and the section
/// shows the change at once.
@MainActor
final class PaperNoteSectionActionsTests: XCTestCase {
    private func margin(_ id: String, session: String, at start: Int, role: PaperNoteRole? = nil) -> Interjection {
        Interjection(
            id: id, itemId: "item-pill", sessionId: session, targetType: .item, targetId: "item-pill",
            createdAt: Date(timeIntervalSince1970: Double(start + 1)), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: start, endChar: start + 5, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed",
            transcript: "Margin \(id)", cleanedTranscript: nil, displayText: "Margin \(id)", status: "active",
            captureKind: .written, paperRole: role
        )
    }

    /// A seeded item with two Margins: one on the open session, one on another session of the same item.
    private func makeModel() throws -> (Gate1AppModel, SQLiteSessionStore, Interjection, Interjection, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "paper-note-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let store = try SQLiteSessionStore(path: url.path)
        let openSessionId = try XCTUnwrap(model.snapshot.sessionId)
        var other = try XCTUnwrap(store.loadSession(id: openSessionId))
        other.id = "other-session"
        try store.saveSession(other)
        let first = margin("first", session: openSessionId, at: 0)
        let second = margin("second", session: other.id, at: 20)
        try store.saveInterjection(first)
        try store.saveInterjection(second)
        model.refreshMarginRows()
        XCTAssertEqual(model.selectedItem.id, "item-pill", "the section reads the open item")
        return (model, store, first, second, root)
    }

    private func saved(_ store: SQLiteSessionStore, _ margin: Interjection) throws -> Interjection {
        try XCTUnwrap(store.loadInterjections(sessionId: margin.sessionId).first { $0.id == margin.id })
    }

    private func filledIds(_ slots: PaperNoteSlots, _ role: PaperNoteRole) -> [String] {
        slots.rows.compactMap { row in
            if case .filled(let answer) = row, row.role == role { return answer.margin.id }
            return nil
        }
    }

    func testChooseFillsASlotAndTheSectionShowsItAtOnce() throws {
        let (model, store, first, second, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(Set(model.paperNoteSlots(document: nil).choices.map(\.margin.id)), ["first", "second"])

        model.setPaperRole(.purpose, for: first)
        model.setPaperRole(.evidence, for: second) // as the details screen's Paper note row does, on another session

        XCTAssertEqual(try saved(store, first).paperRole, .purpose)
        XCTAssertEqual(try saved(store, second).paperRole, .evidence)
        let slots = model.paperNoteSlots(document: nil)
        XCTAssertEqual(filledIds(slots, .purpose), ["first"])
        XCTAssertEqual(filledIds(slots, .evidence), ["second"])
    }

    func testChangeAnswerMovesTheRoleAndKeepsTheOldMargin() throws {
        let (model, store, first, second, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setPaperRole(.purpose, for: first)

        model.changePaperAnswer(.purpose, to: second, replacing: try saved(store, first))

        XCTAssertNil(try saved(store, first).paperRole)
        XCTAssertEqual(try saved(store, first).status, "active", "the old Margin stays")
        XCTAssertEqual(try saved(store, second).paperRole, .purpose)
        XCTAssertEqual(filledIds(model.paperNoteSlots(document: nil), .purpose), ["second"])
    }

    func testRemoveFromPaperNoteEmptiesTheSlotAndKeepsTheMargin() throws {
        let (model, store, first, _, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setPaperRole(.keyFinding, for: first)

        model.setPaperRole(nil, for: try saved(store, first))

        XCTAssertNil(try saved(store, first).paperRole)
        let slots = model.paperNoteSlots(document: nil)
        XCTAssertEqual(filledIds(slots, .keyFinding), [])
        XCTAssertTrue(slots.choices.contains { $0.margin.id == "first" })
    }
}
