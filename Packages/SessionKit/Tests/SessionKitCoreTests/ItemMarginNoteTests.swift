import Foundation
import XCTest
@testable import SessionKit

/// "Send one note per item when I mark it complete" (#587): the per-item note, when it is written, and its file name.
final class ItemMarginNoteTests: XCTestCase {
    private let completedAt = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: The setting

    func testEachMarginStaysTheDefaultForAnyoneWhoNeverChose() {
        XCTAssertEqual(MarginNotesShape(storedValue: nil), .eachMargin)
        XCTAssertEqual(MarginNotesShape(storedValue: "a-later-build's-shape"), .eachMargin)
        XCTAssertEqual(MarginNotesShape(storedValue: "item_on_completion"), .itemOnCompletion)
        XCTAssertTrue(MarginNotesShape.eachMargin.writesEachMargin)
        XCTAssertFalse(MarginNotesShape.itemOnCompletion.writesEachMargin, "per-item mode sends the item note instead")
    }

    func testPerMarginModeWritesNoItemNote() throws {
        let export = try buildExport(margins: [spoken("m1", at: 60_000), spoken("m2", at: 120_000)])
        XCTAssertNil(ItemMarginNote.note(shape: .eachMargin, completedAt: completedAt, exports: [export]))
    }

    // MARK: When the note is written

    func testACompletedItemGetsOneNoteHoldingEveryMarginInOrder() throws {
        // Recorded out of order: the listener sought back to record the earlier one last. Ids sort the wrong way too.
        let export = try buildExport(margins: [
            spoken("a-later-in-episode", at: 754_000, says: "Second thought.", recordedAt: completedAt.addingTimeInterval(-600)),
            spoken("b-earlier-in-episode", at: 60_000, says: "First thought.", recordedAt: completedAt.addingTimeInterval(-60)),
        ])
        let note = try XCTUnwrap(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [export]))

        let properties = try FrontmatterParser.parse(note.markdown)
        XCTAssertEqual(properties["title"], .string("Episode 12"))
        XCTAssertEqual(properties["source"], .string("https://example.com/episodes/12"))
        XCTAssertEqual(properties["author"], .string("The Show"))
        XCTAssertEqual(properties["created"], .plain("2026-04-24T03:06:40Z"))
        XCTAssertEqual(properties["item_id"], .string("item-1"))
        XCTAssertEqual(properties["margin_count"], .plain("2"))
        XCTAssertEqual(properties["tags"], .list(["spoken-margins"]))
        XCTAssertEqual(Array(properties.keys).sorted(), ["author", "created", "item_id", "margin_count", "source", "tags", "title"])

        // The body is the session export the listener already uses.
        XCTAssertTrue(note.markdown.contains("\n# Spoken Margins AI Handoff: Episode 12\n"), note.markdown)
        let first = try XCTUnwrap(note.markdown.range(of: "First thought."))
        let second = try XCTUnwrap(note.markdown.range(of: "Second thought."))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "Margins in listening order")
        XCTAssertTrue(note.markdown.contains("#### 12:34 — Listener interjection"), note.markdown)
    }

    func testListeningAgainDoesNotChangeTheNote() throws {
        let margins = [spoken("m1", at: 60_000)]
        let finished = try buildExport(margins: margins, completionPercent: 100)
        let replaying = try buildExport(margins: margins, completionPercent: 37)
        let first = try XCTUnwrap(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [finished]))
        let later = try XCTUnwrap(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [replaying]))
        XCTAssertEqual(first.markdown, later.markdown, "the writer would otherwise rewrite the note every pass")
        XCTAssertFalse(first.markdown.contains("Completion:"), first.markdown)
    }

    func testAnItemNotCompleteWritesNothing() throws {
        let export = try buildExport(margins: [spoken("m1", at: 60_000)])
        XCTAssertNil(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: nil, exports: [export]))
    }

    func testAnItemWithNoMarginsWritesNothing() throws {
        let empty = try buildExport(margins: [])
        XCTAssertNil(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [empty]))
        XCTAssertNil(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: []))
        let wordless = try buildExport(margins: [written("w1", says: "  ")])
        XCTAssertNil(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [wordless]),
                     "a written Margin with no words gets no note in per-Margin mode either")
    }

    func testCompletingAgainRewritesTheSameFileWithTheNewDate() throws {
        let export = try buildExport(margins: [spoken("m1", at: 60_000)])
        let first = try XCTUnwrap(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [export]))
        // Mark Unfinished, then complete again a day later.
        XCTAssertNil(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: nil, exports: [export]))
        let again = try XCTUnwrap(ItemMarginNote.note(
            shape: .itemOnCompletion, completedAt: completedAt.addingTimeInterval(86_400), exports: [export]
        ))
        XCTAssertEqual(again.fileName, first.fileName)
        XCTAssertEqual(again.id, first.id)
        XCTAssertNotEqual(again.markdown, first.markdown, "the new completion date reaches the file")
        XCTAssertEqual(try FrontmatterParser.parse(again.markdown)["created"], .plain("2026-04-25T03:06:40Z"))
    }

    func testMarginsFromEverySessionOfTheItemAreCounted() throws {
        let earlier = try buildExport(sessionId: "session-a", margins: [spoken("m1", at: 60_000)])
        let later = try buildExport(sessionId: "session-b", margins: [spoken("m2", at: 90_000), spoken("m3", at: 95_000)])
        let note = try XCTUnwrap(ItemMarginNote.note(shape: .itemOnCompletion, completedAt: completedAt, exports: [earlier, later]))
        XCTAssertEqual(try FrontmatterParser.parse(note.markdown)["margin_count"], .plain("3"))
    }

    // MARK: The file name

    func testTheFileNameIsTheTitleWithoutPathCharactersAndStaysPerItem() {
        let name = ItemMarginNote.fileName(title: "Critical / Reading: Notes", itemId: "item-1")
        XCTAssertTrue(name.hasPrefix("Critical Reading Notes — Margins "), name)
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(name, ItemMarginNote.fileName(title: "Critical / Reading: Notes", itemId: "item-1"))
        XCTAssertNotEqual(name, ItemMarginNote.fileName(title: "Critical / Reading: Notes", itemId: "item-2"),
                          "two items with the same title don't overwrite each other")
        XCTAssertTrue(ItemMarginNote.fileName(title: " / ", itemId: "item-1").hasPrefix("Untitled — Margins "))
    }

    func testCharactersShareFoldersRefuseAreDropped() {
        let name = ItemMarginNote.fileName(title: #"Why now? "Quoted" <a|b>*."#, itemId: "item-1")
        XCTAssertTrue(name.hasPrefix("Why now Quoted a b — Margins "), name)
    }

    func testALongTitleInAnyScriptStaysUnderTheFileNameLimit() {
        let japanese = String(repeating: "日本語のポッドキャスト", count: 20)
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 40)
        for title in [japanese, emoji, String(repeating: "a", count: 400)] {
            let name = ItemMarginNote.fileName(title: title, itemId: "item-1")
            XCTAssertLessThanOrEqual(name.utf8.count, 255, name)
            XCTAssertTrue(name.hasSuffix(".md"))
        }
    }

    func testTheItemNoteNeverSharesAKeyWithAMarginNote() {
        // Margin notes use "<session id>:<margin id>".
        XCTAssertEqual(ItemMarginNote.noteID(itemId: "item-1"), "item:item-1")
    }

    // MARK: Fixtures

    private let item = Item(
        id: "item-1", title: "Episode 12", mediaType: "audio", text: nil,
        externalReference: "https://example.com/episodes/12", status: "ready",
        media: ItemMedia(sourceType: .nativeMediaFile, url: "https://cdn.example.com/12.mp3", durationMs: 3_600_000),
        author: "The Show"
    )

    private func spoken(_ id: String, at mediaTimeMs: Int, says text: String = "A thought.", recordedAt: Date? = nil) -> Interjection {
        var margin = margin(id, kind: nil, mediaTimeMs: mediaTimeMs, text: text)
        margin.createdAt = recordedAt ?? completedAt
        return margin
    }

    private func written(_ id: String, says text: String) -> Interjection {
        margin(id, kind: .written, mediaTimeMs: nil, text: text)
    }

    private func margin(_ id: String, kind: InterjectionCaptureKind?, mediaTimeMs: Int?, text: String) -> Interjection {
        Interjection(
            id: id, itemId: item.id, sessionId: "", targetType: .item, targetId: item.id,
            createdAt: completedAt, roughPercent: 0,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: 0, endChar: 0,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: kind == .written ? "discarded" : "saved",
            transcriptionStatus: "transcribed", transcript: text, cleanedTranscript: nil,
            displayText: text, status: "active", captureKind: kind
        )
    }

    /// One session's export, built with the notes-folder gatherer's options for a whole session.
    private func buildExport(
        sessionId: String = "session-1", margins: [Interjection], completionPercent: Int = 100
    ) throws -> SessionExport {
        let session = Session(id: sessionId, itemId: item.id, status: completionPercent == 100 ? "completed" : "in_progress",
                              phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
                              position: Position(), completionPercent: completionPercent, playbackRate: 1)
        var byId: [String: Interjection] = [:]
        for var margin in margins {
            margin.sessionId = sessionId
            byId[margin.id] = margin
        }
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: byId)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: repository
        )
        return try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false
        ))
    }
}
