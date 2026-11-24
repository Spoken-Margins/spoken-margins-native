import Foundation
import XCTest
@testable import SessionKit

/// #4340 PR 5 and PR 6 of the Design: the Write sheet's places, words and prompt order, the section's footnote, which
/// items are papers, and the Paper notes table export's scope, words and files.
final class PaperNoteWriteTests: XCTestCase {
    private let text = "Page one first. Page one second.\nPage two first. Page two last.\nPage three only."
    private lazy var document = StructuredDocument(
        extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 3, textSHA256: nil),
        text: text,
        segments: [
            .init(id: "s0", role: .body, range: .init(start: 0, length: 15), pageIndex: 0),
            .init(id: "s1", role: .body, range: .init(start: 16, length: 16), pageIndex: 0),
            .init(id: "s2", role: .body, range: .init(start: 33, length: 15), pageIndex: 1),
            .init(id: "s3", role: .body, range: .init(start: 49, length: 14), pageIndex: 1),
            .init(id: "s4", role: .body, range: .init(start: 64, length: 16), pageIndex: 2),
        ],
        markers: []
    )
    private var item: Item { Item(id: "paper", title: "Sleep", mediaType: "pdf", text: text, externalReference: nil, status: "ready") }

    private func session(at charOffset: Int, percent: Int = 30, target: TargetType = .itemTextTTS, item: String = "paper") -> Session {
        Session(
            id: "s-\(item)-\(charOffset)", itemId: item, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            status: "in_progress", phase: .itemPlayback, currentTargetType: target, currentTargetId: item,
            position: Position(charOffset: charOffset), completionPercent: percent, playbackRate: 1
        )
    }

    private func context(_ sessions: [Session], document: StructuredDocument? = nil, item: Item? = nil) -> PaperNoteWriteContext {
        PaperNoteWriteContext(item: item ?? self.item, document: document, sessions: sessions, addedAgainAt: nil)
    }

    // MARK: Places

    func testWhereYouAreReadsThePageOfTheSavedPlace() throws {
        let write = context([session(at: 35)], document: document)
        XCTAssertTrue(write.canWrite)
        XCTAssertEqual(write.choices, [.whereYouAre, .startOfPaper, .startOfPage(1)])
        XCTAssertEqual(write.defaultChoice, .whereYouAre)
        XCTAssertEqual(try write.character(for: .whereYouAre), 35)
        XCTAssertEqual(write.placeLine(.whereYouAre), "At p. 2, where you are")
        XCTAssertEqual(write.menuTitle(.whereYouAre), "Where you are (p. 2)")
        XCTAssertEqual(write.placeLine(.startOfPaper), "At the start of the paper")
        XCTAssertEqual(write.menuTitle(.startOfPaper), "Start of the paper")
        XCTAssertEqual(write.placeLine(.startOfPage(3)), "At the start of p. 3")
        XCTAssertEqual(write.menuTitle(.startOfPage(3)), "Start of a page…")
        XCTAssertEqual(try write.character(for: .startOfPage(3)), 64)
        XCTAssertEqual(write.pageCount, 3)
    }

    /// A place in the last segment of a page may run over onto the next, so the document gives no page; the words then
    /// leave the page out, as the answer's own row will ("At 40%").
    func testAnUncertainPageIsLeftOutOfTheWords() {
        let write = context([session(at: 55)], document: document)
        XCTAssertNil(write.page(for: .whereYouAre))
        XCTAssertEqual(write.placeLine(.whereYouAre), "Where you are")
    }

    func testWithoutAStructureThereIsNoPageChoiceAndNoPageInTheWords() {
        let write = context([session(at: 40)])
        XCTAssertEqual(write.choices, [.whereYouAre, .startOfPaper])
        XCTAssertNil(write.pageCount)
        XCTAssertEqual(write.placeLine(.whereYouAre), "Where you are")
        XCTAssertEqual(write.menuTitle(.whereYouAre), "Where you are")
    }

    func testANeverStartedPaperCannotBeWrittenTo() {
        let write = context([], document: document)
        XCTAssertFalse(write.canWrite)
        XCTAssertEqual(write.choices, [])
        XCTAssertEqual(PaperNoteSlots.footnote(canWrite: write.canWrite), "Start listening to place your answers where you are in the paper.")
        XCTAssertNil(PaperNoteSlots.footnote(canWrite: true))
    }

    func testAnotherItemsSessionDoesNotCount() {
        XCTAssertFalse(context([session(at: 10, item: "other")], document: document).canWrite)
    }

    func testAPaperWithNoTextCannotBeWrittenTo() {
        let empty = Item(id: "paper", title: "Scan", mediaType: "pdf", text: "", externalReference: nil, status: "ready")
        XCTAssertFalse(context([session(at: 0)], item: empty).canWrite)
    }

    func testWhileAGeneratedAnswerPlaysWhereYouAreIsNotOfferedAndTheStartOfThePaperIs() {
        let write = context([session(at: 5, target: .assistantTurnTTS)], document: document)
        XCTAssertTrue(write.canWrite)
        XCTAssertFalse(write.choices.contains(.whereYouAre))
        XCTAssertEqual(write.defaultChoice, .startOfPaper)
    }

    // MARK: Prompt order

    private func slots(_ roles: [PaperNoteRole]) -> PaperNoteSlots {
        let margins = roles.enumerated().map { index, role in
            Interjection(
                id: "m\(index)", itemId: "paper", sessionId: "s", targetType: .item, targetId: "paper",
                createdAt: Date(timeIntervalSince1970: Double(index)), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: index, endChar: index + 1, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "words", status: "active", captureKind: .written, paperRole: role
            )
        }
        return PaperNoteSlots(paper: .init(itemId: "paper", title: "Sleep", margins: margins))
    }

    func testPromptsStartAtTheTappedSlotThenRunThroughTheOtherEmptyOnes() {
        var prompts = PaperNoteWritePrompts(start: .purpose, slots: slots([]))
        XCTAssertEqual(prompts.remaining, [.purpose, .keyFinding, .evidence, .evidence, .evidence])
        prompts.advance()
        XCTAssertEqual(prompts.current, .keyFinding)

        let fromEvidence = PaperNoteWritePrompts(start: .evidence, slots: slots([.purpose]))
        XCTAssertEqual(fromEvidence.remaining, [.evidence, .keyFinding, .evidence, .evidence])
    }

    func testAddMoreEvidenceAsksForOneEvidenceAndThenCloses() {
        var prompts = PaperNoteWritePrompts(start: .evidence, slots: slots([.purpose, .keyFinding, .evidence, .evidence, .evidence]))
        XCTAssertEqual(prompts.remaining, [.evidence])
        prompts.advance()
        XCTAssertNil(prompts.current)
        prompts.advance()
        XCTAssertNil(prompts.current, "advancing past the end is harmless")
    }

    func testChangeAnswerAsksForThatRoleOnly() {
        var prompts = PaperNoteWritePrompts(only: .keyFinding)
        XCTAssertEqual(prompts.remaining, [.keyFinding])
        prompts.advance()
        XCTAssertNil(prompts.current)
    }

    func testSavedLineNamesTheSlot() {
        XCTAssertEqual(PaperNoteWriteContext.savedLine(.purpose), "Purpose saved.")
        XCTAssertEqual(PaperNoteWriteContext.savedLine(.keyFinding), "Key findings saved.")
    }

    // MARK: Which items are papers

    func testIsPaperFollowsTheLibrarysPDFRuleExceptForAnotherDocumentsExtension() {
        let rows: [(String, String?, String?, Bool)] = [
            ("pdf", nil, nil, true),
            ("text", "paper.pdf", "file", true),
            ("text", "PAPER.PDF", "file", true),
            ("text", "https://example.org/files/paper.pdf?download=1#page=2", "url", true),
            ("text", "x.pdf.docx", "file", false),
            ("text", "X.PDF.DOCX", "file", false),
            ("text", "notes.pdf.txt", "file", false),
            ("text", "book.pdf.epub", "file", false),
            ("text", "https://example.org/a.pdf.html", "url", false),
            ("text", "notes.txt", "file", false),
            ("article", "https://example.org/story", "url", false),
            ("pdf", "  ", "file", true),
            ("text", "x.pdf.pptx", "file", false),
            ("text", "x.pdf.xlsx", "file", false),
            ("text", "x.pdf.key", "file", false),
            ("text", "x.pdf.csv", "file", false),
            ("text", "Notes #2.pdf.docx", "file", false),
            ("text", "Notes #2.pdf", "file", true),
            ("text", "What? Why.pdf", "file", true),
            ("article", "https://www.pdfx.pdf-host.com/article", "url", false),
            ("text", "https://www.pdf-host.com/", "url", false),
            ("text", "paper.PDF ", "file", true),
            ("text", nil, nil, false),
        ]
        for (media, reference, type, expected) in rows {
            XCTAssertEqual(
                PaperNoteSlots.isPaper(mediaType: media, sourceReference: reference, sourceReferenceType: type), expected,
                "\(media) \(reference ?? "nil")")
        }
    }

    // MARK: Table export

    func testScopeNameAndMessage() {
        let everything = MarginCollectionQuery()
        XCTAssertEqual(PaperNoteTableExport.scopeName(everything, collectionName: nil, itemTitle: nil), "your whole Library")
        let item = MarginCollectionQuery(itemID: "paper")
        XCTAssertEqual(PaperNoteTableExport.scopeName(item, collectionName: nil, itemTitle: " Sleep "), "Sleep")
        XCTAssertEqual(PaperNoteTableExport.scopeName(item, collectionName: nil, itemTitle: ""), "Untitled")
        let course = MarginCollectionQuery(collection: ItemCollectionScope(ItemCollection(id: "c", name: "Bio 101", itemIDs: ["paper"], createdAt: Date(timeIntervalSince1970: 1))))
        XCTAssertEqual(PaperNoteTableExport.scopeName(course, collectionName: "Bio 101", itemTitle: nil), "Bio 101")
        XCTAssertEqual(PaperNoteTableExport.scopeName(course, collectionName: nil, itemTitle: nil), "this collection")
        XCTAssertEqual(PaperNoteTableExport.dialogMessage(scopeName: "Bio 101"), "One row per paper with a paper note, in Bio 101.")
    }

    func testScopeFollowsTheCollectionOrItemButNotTheSearchText() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(PaperNoteTableExport.scope(MarginCollectionQuery(text: "zzz"), itemIDs: ids), ["a", "b", "c"])
        XCTAssertEqual(PaperNoteTableExport.scope(MarginCollectionQuery(itemID: "b"), itemIDs: ids), ["b"])
        let course = MarginCollectionQuery(collection: ItemCollectionScope(ItemCollection(id: "c", name: "Bio", itemIDs: ["a", "c", "z"], createdAt: Date(timeIntervalSince1970: 1))))
        XCTAssertEqual(PaperNoteTableExport.scope(course, itemIDs: ids), ["a", "c"])
    }

    func testHasAnswersNeedsAnOwnActiveRoleMarginInScope() {
        func margin(_ item: String, _ role: PaperNoteRole?, status: String = "active") -> Interjection {
            Interjection(
                id: "m-\(item)", itemId: item, sessionId: "s", targetType: .item, targetId: item,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "words", status: status, captureKind: .written, paperRole: role
            )
        }
        XCTAssertTrue(PaperNoteTableExport.hasAnswers([margin("a", .purpose)], scope: ["a"]))
        XCTAssertFalse(PaperNoteTableExport.hasAnswers([margin("a", .purpose)], scope: ["b"]))
        XCTAssertFalse(PaperNoteTableExport.hasAnswers([margin("a", nil)], scope: ["a"]))
        XCTAssertFalse(PaperNoteTableExport.hasAnswers([margin("a", .purpose, status: "deleted")], scope: ["a"]))
    }

    func testWriteMakesTheNamedFileInAFreshFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-table-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let margin = Interjection(
            id: "m", itemId: "paper", sessionId: "s", targetType: .item, targetId: "paper",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "Café, aim", status: "active", captureKind: .written, paperRole: .purpose
        )
        let table = PaperNoteTable(papers: [.init(itemId: "paper", title: "Sleep", margins: [margin])])
        let csv = try PaperNoteTableExport.write(table, format: .csv, under: root)
        let markdown = try PaperNoteTableExport.write(table, format: .markdown, under: root)
        XCTAssertEqual(csv.lastPathComponent, "Paper notes.csv")
        XCTAssertEqual(markdown.lastPathComponent, "Paper notes.md")
        XCTAssertNotEqual(csv.deletingLastPathComponent(), markdown.deletingLastPathComponent(), "each export has its own folder")
        XCTAssertEqual(csv.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        let bytes = try Data(contentsOf: csv)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"Café, aim\""))
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), table.markdown())
    }
}
