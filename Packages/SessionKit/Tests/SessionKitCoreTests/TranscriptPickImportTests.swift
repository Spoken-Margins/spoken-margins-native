import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitPersistence
@testable import SessionKitEPUB

/// #2997 PR 4: what a pick from Files does with the files the transcript rule reads, on real temporary files and a
/// real SQLite store. The pick's banner words are in `TranscriptPickBannerTests`.
final class TranscriptPickImportTests: XCTestCase {
    private var root: URL!
    private var path: String!
    private var store: SQLiteSessionStore!
    private let utc = TimeZone(identifier: "UTC")!
    private let docx: @Sendable (Data) throws -> String = { try DocxPlainText.text(from: $0) }
    private let essay = "A short essay about nothing in particular.\n\nIt has two paragraphs and no meeting in it."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL { try write(name, Data(text.utf8)) }

    private func writeDocx(_ name: String, paragraphs: [String]) throws -> URL {
        let body = paragraphs.map { "<w:p><w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r></w:p>" }.joined()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """.utf8)
        let url = root.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(xml.count)) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
        return url
    }

    private func run(_ urls: [URL], stillListening: Set<String> = []) async throws -> TranscriptPickImport.Result {
        try await TranscriptPickImport.run(
            urls: urls, store: store, docxText: docx, now: Date(timeIntervalSince1970: 1_000),
            stillListeningItemIds: stillListening, timeZone: utc)
    }

    private func itemCount() throws -> Int { try StoreRawSQL.ids(kind: "item", at: path).count }

    // MARK: Which files the rule reads

    func testOnlyVttSrtDocxAndTxtAreCandidatesWhateverTheirCase() {
        for name in ["a.vtt", "a.SRT", "a.Docx", "a.txt", "a.transcript.vtt", "Zoom GMT20260304-100000.TXT"] {
            XCTAssertTrue(TranscriptPickImport.isCandidate(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.md", "a.pdf", "a.epub", "a.json", "a.doc", "a.rtf", "a.vtt.bak", "a", ".txt.", "a.mp3"] {
            XCTAssertFalse(TranscriptPickImport.isCandidate(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    // MARK: Files that import

    func testEachFormatImportsAsATranscriptAndNothingIsPassedThrough() async throws {
        let vtt = try write("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        let srt = try write("generic.srt", TranscriptFixtures.all["generic.srt"]!)
        let txt = try write("otter.txt", TranscriptFixtures.all["otter.txt"]!)
        // Each fixture says the same words, so in one store they are one item; the order picked is the order added.
        let result = try await run([vtt, srt, txt])
        XCTAssertEqual(result.added.count, 3)
        XCTAssertEqual(result.added.map(\.itemId), Array(repeating: result.added[0].itemId, count: 3))
        XCTAssertEqual(result.added.map(\.readded), [false, true, true])
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertTrue(result.passthrough.isEmpty)
        XCTAssertTrue(result.handledAnyTranscript)
        XCTAssertEqual(try itemCount(), 1)
    }

    /// #4594: a Word essay is a document now. Before, it was refused with "isn't a meeting transcript".
    func testAWordTranscriptImportsAndAWordEssayGoesToTheDocumentImport() async throws {
        let meeting = try writeDocx("meeting.docx", paragraphs: [
            "Budget sync", "Alice Example\t0:03", "Welcome everyone, let's start with the budget.",
            "Ben Sample\t0:06", "Thanks. I have the draft numbers ready.", "Alice Example\t0:09", "Great, please share them.",
        ])
        let essayDocx = try writeDocx("essay.docx", paragraphs: [essay, "A second paragraph of the essay."])
        let result = try await run([meeting, essayDocx])
        XCTAssertEqual(result.added.map(\.title).count, 1)
        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["essay.docx"], "the essay goes on to the document import")
        XCTAssertEqual(try itemCount(), 1, "the pick itself saves only the transcript")
    }

    /// #4594: a Word file the transcript rule can't read, finds empty, or that is over the transcript cap, goes on to the
    /// document import, which refuses it in a document's words (a password, the old format) or reads it.
    func testAWordFileThatWontOpenIsEmptyOrLargeGoesToTheDocumentImport() async throws {
        let bad = try write("broken.docx", "this is not a zip file")
        let empty = try writeDocx("empty.docx", paragraphs: ["", "  "])
        let large = try writeDocx("large.docx", paragraphs: [String(repeating: "Four score and seven years ago. ", count: 10)])
        let paddedSize = TranscriptImport.maximumBytes + 1
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(paddedSize))
        try handle.close()
        let result = try await run([bad, empty, large])
        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["broken.docx", "empty.docx", "large.docx"])
        XCTAssertEqual(try itemCount(), 0)
    }

    // MARK: Files that stay with today's import

    func testAPlainEssayTxtAndEveryOtherTypeComeBackInTheOrderPickedWithNothingSaved() async throws {
        let first = try write("essay.txt", essay)
        let notes = try write("notes.md", "# Notes\n\nSome notes.")
        let pdf = try write("paper.pdf", "%PDF-1.4 not really")
        let last = try write("agenda.txt", "Agenda\n\n10:00 Welcome\n10:15 Budget\n10:30 Close")
        let result = try await run([first, notes, pdf, last])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["essay.txt", "notes.md", "paper.pdf", "agenda.txt"])
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertFalse(result.handledAnyTranscript, "no transcript was handled, so the pick keeps today's words")
        XCTAssertEqual(try itemCount(), 0)
    }

    func testAMixedPickSplitsTheTranscriptFromTheRest() async throws {
        let vtt = try write("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let md = try write("notes.md", "# Notes")
        let result = try await run([md, vtt])
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["notes.md"])
    }

    // MARK: Refusals

    func testEmptyAndWhitespaceFilesAreRefusedWithTheirNames() async throws {
        let zero = try write("zero.vtt", Data())
        let blank = try write("blank.txt", " \n\t \n")
        let result = try await run([zero, blank])
        XCTAssertEqual(result.refusals, [
            TranscriptImportMessage(.empty, fileName: "zero.vtt"), TranscriptImportMessage(.empty, fileName: "blank.txt"),
        ])
        XCTAssertTrue(result.added.isEmpty)
    }

    func testATxtThatIsNotUTF8AndNotATranscriptKeepsTodaysImportButANonUTF8VttIsRefused() async throws {
        let latin1 = try write("cafe.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x6D, 0x65, 0x6E, 0x75, 0x0A, 0x81, 0x82]))
        let vtt = try write("odd.vtt", Data([0x57, 0x45, 0x42, 0x56, 0x54, 0x54, 0x0A, 0x0A, 0x81, 0x82, 0x83]))
        let result = try await run([latin1, vtt])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["cafe.txt"])
        XCTAssertEqual(result.refusals.map(\.fileName), ["odd.vtt"])
    }

    func testAVttWithNoTimedLinesIsRefused() async throws {
        let url = try write("notes.vtt", "WEBVTT\n\nJust some words with no timing at all.\n")
        let result = try await run([url])
        XCTAssertEqual(result.refusals, [TranscriptImportMessage(.noTimedLines, fileName: "notes.vtt")])
    }

    func testAFileThatIsGoneIsRefusedAsCouldNotRead() async throws {
        let url = root.appendingPathComponent("gone.vtt")
        let result = try await run([url])
        XCTAssertEqual(result.refusals, [TranscriptImportMessage(.couldNotRead, fileName: "gone.vtt")])
    }

    /// A `.docx` over the transcript cap goes to the document import, which has its own cap (#4594).
    func testAnOverTheCapVttIsRefusedAndAnOverTheCapTxtOrDocxGoesToTodaysImportWithoutBeingRead() async throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: TranscriptImport.maximumBytes + 1)
        let vtt = try write("big.vtt", big)
        let srt = try write("big.srt", big)
        let docx = try write("big.docx", big)
        let txt = try write("big.txt", big)
        let result = try await run([vtt, srt, docx, txt])
        XCTAssertEqual(result.refusals.map(\.kind), [.tooLarge, .tooLarge])
        XCTAssertEqual(result.refusals.map(\.fileName), ["big.vtt", "big.srt"])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["big.docx", "big.txt"])
        XCTAssertEqual(try itemCount(), 0)
    }

    func testAFileJustUnderTheCapStillImports() async throws {
        let head = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nAlice Example: Hello there.\n\n00:00:03.000 --> 00:00:04.000\nBen Sample: Hi.\n\n"
        var text = head
        let filler = "00:00:05.000 --> 00:00:06.000\nAlice Example: " + String(repeating: "w", count: 900) + "\n\n"
        while text.utf8.count + filler.utf8.count < TranscriptImport.maximumBytes - 1_000 { text += filler }
        let url = try write("long.vtt", text)
        let result = try await run([url])
        XCTAssertEqual(result.added.count, 1)
        XCTAssertTrue(result.refusals.isEmpty)
    }

    // MARK: Adding again

    func testThePickedTranscriptAgainIsTheSameItemMarkedAddedAgain() async throws {
        let url = try write("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let first = try await run([url])
        let second = try await run([url])
        XCTAssertEqual(second.added.map(\.itemId), first.added.map(\.itemId))
        XCTAssertEqual(first.added.map(\.readded), [false])
        XCTAssertEqual(second.added.map(\.readded), [true])
        XCTAssertEqual(try itemCount(), 1)
    }

    func testATranscriptTheListenerIsStillInIsLeftAsItIs() async throws {
        let url = try write("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let first = try await run([url])
        let id = try XCTUnwrap(first.added.first?.itemId)
        let stamped = try store.loadItem(id: id)
        _ = try await run([url], stillListening: [id])
        XCTAssertEqual(try store.loadItem(id: id).addedAgainAt, stamped.addedAgainAt, "no new added-again stamp while the listener is in it")
    }

    // MARK: The order a queue takes the pick's items in (#2997, the Quick Folder's queue paths)

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/folder/\(name)") }

    private func added(_ name: String, id: String) -> TranscriptPickImport.Added {
        TranscriptPickImport.Added(itemId: id, title: name, readded: false, url: file(name))
    }

    func testQueueOrderFollowsThePickAcrossTranscriptsAndTextFiles() {
        let picked = ["a.txt", "b.vtt", "c.txt", "d.srt"].map(file)
        let ids = TranscriptPickImport.itemIdsInPickOrder(
            picked: picked,
            added: [added("b.vtt", id: "B"), added("d.srt", id: "D")],
            passthrough: [file("a.txt"), file("c.txt")],
            textItemIds: ["A", "C"])
        XCTAssertEqual(ids, ["A", "B", "C", "D"])
    }

    func testQueueOrderTableOfNeighbouringPicks() {
        struct Row { var name: String; var picked: [String]; var added: [(String, String)]; var passthrough: [String]; var text: [String]; var expected: [String] }
        let rows = [
            Row(name: "nothing picked", picked: [], added: [], passthrough: [], text: [], expected: []),
            Row(name: "text only keeps the text import's order", picked: ["a.md", "b.txt"], added: [], passthrough: ["a.md", "b.txt"], text: ["A", "B"], expected: ["A", "B"]),
            Row(name: "transcripts only", picked: ["b.vtt", "a.vtt"], added: [("b.vtt", "B"), ("a.vtt", "A")], passthrough: [], text: [], expected: ["B", "A"]),
            Row(name: "a refused transcript adds nothing and leaves a gap", picked: ["a.vtt", "bad.vtt", "c.vtt"], added: [("a.vtt", "A"), ("c.vtt", "C")], passthrough: [], text: [], expected: ["A", "C"]),
            Row(name: "a refused word file between two text files", picked: ["a.md", "essay.docx", "c.md"], added: [], passthrough: ["a.md", "c.md"], text: ["A", "C"], expected: ["A", "C"]),
            Row(name: "the same transcript twice is one id at its first place", picked: ["a.vtt", "b.md", "a.vtt"], added: [("a.vtt", "A"), ("a.vtt", "A")], passthrough: ["b.md"], text: ["B"], expected: ["A", "B"]),
            Row(name: "no text item saved leaves only the transcripts", picked: ["a.md", "b.vtt"], added: [("b.vtt", "B")], passthrough: ["a.md"], text: [], expected: ["B"]),
            Row(name: "upper-case extensions and spaces in names", picked: ["Zoom Call.TXT", "x y.VTT"], added: [("x y.VTT", "X")], passthrough: ["Zoom Call.TXT"], text: ["Z"], expected: ["Z", "X"]),
        ]
        for row in rows {
            let ids = TranscriptPickImport.itemIdsInPickOrder(
                picked: row.picked.map(file),
                added: row.added.map { added($0.0, id: $0.1) },
                passthrough: row.passthrough.map(file),
                textItemIds: row.text)
            XCTAssertEqual(ids, row.expected, row.name)
        }
    }

    func testAFailedTextFileNeverDropsOrDuplicatesAnId() {
        // The text import saved one of two files and the pick cannot say which; the ids still all come out, once each.
        let ids = TranscriptPickImport.itemIdsInPickOrder(
            picked: ["a.md", "b.vtt", "c.md"].map(file),
            added: [added("b.vtt", id: "B")],
            passthrough: [file("a.md"), file("c.md")],
            textItemIds: ["C"])
        XCTAssertEqual(Set(ids), ["B", "C"])
        XCTAssertEqual(ids.count, 2)
    }

    func testARealPickCarriesEachTranscriptsFileSoTheQueueOrderFollowsThePick() async throws {
        let first = try write("first.txt", essay)
        let meeting = try write("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let last = try write("last.md", "# Last")
        let result = try await run([first, meeting, last])
        XCTAssertEqual(result.added.map(\.url), [meeting])
        let ids = TranscriptPickImport.itemIdsInPickOrder(
            picked: [first, meeting, last], added: result.added, passthrough: result.passthrough,
            textItemIds: ["text-first", "text-last"])
        XCTAssertEqual(ids, ["text-first", try XCTUnwrap(result.added.first?.itemId), "text-last"])
    }
}
