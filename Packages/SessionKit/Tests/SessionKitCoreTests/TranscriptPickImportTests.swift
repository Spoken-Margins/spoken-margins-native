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

    func testAWordTranscriptImportsAndAWordEssayIsRefusedWithItsOwnSentence() async throws {
        let meeting = try writeDocx("meeting.docx", paragraphs: [
            "Budget sync", "Alice Example\t0:03", "Welcome everyone, let's start with the budget.",
            "Ben Sample\t0:06", "Thanks. I have the draft numbers ready.", "Alice Example\t0:09", "Great, please share them.",
        ])
        let essayDocx = try writeDocx("essay.docx", paragraphs: [essay, "A second paragraph of the essay."])
        let result = try await run([meeting, essayDocx])
        XCTAssertEqual(result.added.map(\.title).count, 1)
        XCTAssertEqual(result.refusals, [TranscriptImportMessage(.docxNotATranscript, fileName: "essay.docx")])
        XCTAssertTrue(result.passthrough.isEmpty, "a Word file that isn't a transcript is never imported as text")
        XCTAssertEqual(try itemCount(), 1)
    }

    func testAWordFileThatWontUnzipIsRefusedAsUnreadable() async throws {
        let bad = try write("broken.docx", "this is not a zip file")
        let result = try await run([bad])
        XCTAssertEqual(result.refusals, [TranscriptImportMessage(.docxUnreadable, fileName: "broken.docx")])
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

    func testAnOverTheCapVttIsRefusedAndAnOverTheCapTxtGoesToTodaysImportWithoutBeingRead() async throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: TranscriptImport.maximumBytes + 1)
        let vtt = try write("big.vtt", big)
        let srt = try write("big.srt", big)
        let docx = try write("big.docx", big)
        let txt = try write("big.txt", big)
        let result = try await run([vtt, srt, docx, txt])
        XCTAssertEqual(result.refusals.map(\.kind), [.tooLarge, .tooLarge, .tooLarge])
        XCTAssertEqual(result.refusals.map(\.fileName), ["big.vtt", "big.srt", "big.docx"])
        XCTAssertEqual(result.passthrough.map(\.lastPathComponent), ["big.txt"])
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
}
