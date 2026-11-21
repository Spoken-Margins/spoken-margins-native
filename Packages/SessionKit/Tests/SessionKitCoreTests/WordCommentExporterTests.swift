import Foundation
@testable import SessionKit
@testable import SessionKitEPUB
import SessionKitTestInputs
import XCTest
import ZIPFoundation

/// #4595: what the "Word document with your Margins" sheet asks of the package: where each comment would land (before
/// anything is written), and a copy with only the comments the listener kept. Real `.docx` fixtures, real files.
final class WordCommentExporterTests: XCTestCase {
    private static let folder = TestInputs.packageURL("Tests/SessionKitCoreTests/Fixtures/DocxComments")
    private let sentence = "Mr. Bennet replied that he had not."
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "word-exporter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func entry(_ id: String, sentence: String, words: String, status: MarginCommentPlan.Entry.Status = .included) -> MarginCommentPlan.Entry {
        MarginCommentPlan.Entry(
            marginId: id, sentence: nil, sentenceText: sentence, precedingText: "", pageIndex: nil,
            commentText: status == .included ? words : "", status: status
        )
    }

    private func plan(_ entries: MarginCommentPlan.Entry...) -> MarginCommentPlan { MarginCommentPlan(entries: entries) }

    /// The comments in a written copy: author and words, read with a plain pattern over `word/comments.xml`.
    private func comments(in file: URL) throws -> [(author: String, text: String)] {
        let archive = try Archive(url: file, accessMode: .read)
        guard let entry = archive["word/comments.xml"] else { return [] }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = String(decoding: data, as: UTF8.self)
        let comment = try NSRegularExpression(pattern: #"<w:comment [^>]*w:author="([^"]*)"[^>]*>(.*?)</w:comment>"#, options: [.dotMatchesLineSeparators])
        let text = try NSRegularExpression(pattern: #"<w:t[^>]*>([^<]*)</w:t>"#)
        return comment.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).map { match in
            let author = String(xml[Range(match.range(at: 1), in: xml)!])
            let body = String(xml[Range(match.range(at: 2), in: xml)!])
            let words = text.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
            return (author, words.joined())
        }
    }

    private func commentCount(in file: URL) throws -> Int { try comments(in: file).count }

    func testThePreviewNamesEachSpotWithoutWritingAndMatchesWhatTheWriterDoes() throws {
        let source = Self.folder.appending(path: "one-run.docx")
        let before = try Data(contentsOf: source)
        let margins = plan(
            entry("found", sentence: sentence, words: "Short."),
            entry("lost", sentence: "A sentence that is nowhere in this book.", words: "Gone."),
            entry("pending", sentence: sentence, words: "", status: .transcriptPending)
        )
        let preview = try WordCommentExporter.preview(source: source, plan: margins)
        XCTAssertEqual(preview.placements.map(\.marginId), ["found", "lost"], "a Margin with no words is not placed")
        XCTAssertEqual(preview.spots["found"], .wordSentence(whole: true))
        XCTAssertEqual(preview.spots["lost"], .wordFirstParagraph)
        XCTAssertNil(preview.spots["pending"])
        XCTAssertEqual(try Data(contentsOf: source), before, "the preview only reads")

        let output = scratch.appending(path: "out.docx")
        let written = try DocxCommentWriter.write(
            source: source, requests: margins.included.map(DocxCommentWriter.Request.init(entry:)), author: "A", to: output)
        XCTAssertEqual(written, preview.placements, "what the sheet says is what the writer does")
    }

    func testEveryFixtureOfTheTableHasTheSameSpotsInThePreviewAsInTheWrittenCopy() throws {
        struct Manifest: Decodable {
            struct Case: Decodable {
                struct Margin: Decodable { var marginId: String; var sentenceText: String; var precedingText: String; var commentText: String }
                var name: String
                var file: String
                var margins: [Margin]
            }
            var cases: [Case]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.folder.appending(path: "cases.json")))
        XCTAssertEqual(manifest.cases.count, 10)
        for testCase in manifest.cases {
            let source = Self.folder.appending(path: testCase.file)
            let entries = testCase.margins.map {
                MarginCommentPlan.Entry(
                    marginId: $0.marginId, sentence: nil, sentenceText: $0.sentenceText, precedingText: $0.precedingText,
                    pageIndex: nil, commentText: $0.commentText, status: .included)
            }
            let margins = MarginCommentPlan(entries: entries)
            let preview = try WordCommentExporter.preview(source: source, plan: margins)
            let output = scratch.appending(path: testCase.file)
            let count = try WordCommentExporter.export(source: source, plan: margins, includedIds: entries.map(\.marginId), author: "A", to: output)
            XCTAssertEqual(count, entries.count, testCase.name)
            let written = try DocxCommentWriter.write(
                source: source, requests: margins.included.map(DocxCommentWriter.Request.init(entry:)), author: "B",
                to: scratch.appending(path: "again-" + testCase.file))
            XCTAssertEqual(preview.placements, written, "\(testCase.name): what the sheet says is what the writer does")
            XCTAssertEqual(try comments(in: output).filter { $0.author == "A" }.count, entries.count, testCase.name)
        }
    }

    func testOnlyTheMarginsTheListenerKeptAreWritten() throws {
        let source = Self.folder.appending(path: "one-run.docx")
        let margins = plan(
            entry("keep", sentence: sentence, words: "Keep me."),
            entry("leave-out", sentence: sentence, words: "Not this one."),
            entry("pending", sentence: sentence, words: "", status: .noTranscript)
        )
        let output = scratch.appending(path: "kept.docx")
        let count = try WordCommentExporter.export(source: source, plan: margins, includedIds: ["keep", "pending"], author: "Ada", to: output)
        XCTAssertEqual(count, 1, "a Margin with no words is never written, even if its id is passed")
        let written = try comments(in: output)
        XCTAssertEqual(written.map(\.text), ["Keep me."])
        XCTAssertEqual(written.map(\.author), ["Ada"])
    }

    func testNothingKeptStillWritesAValidCopyWithNoNewComments() throws {
        let output = scratch.appending(path: "none.docx")
        let count = try WordCommentExporter.export(
            source: Self.folder.appending(path: "one-run.docx"), plan: plan(entry("a", sentence: sentence, words: "x")),
            includedIds: [], author: "", to: output)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try commentCount(in: output), 0)
    }

    func testAFileThatIsNotAWordDocumentIsRefusedAndNothingIsWritten() throws {
        let notDocx = scratch.appending(path: "notes.docx")
        try Data("plain text, not a zip".utf8).write(to: notDocx)
        let margins = plan(entry("a", sentence: sentence, words: "x"))
        XCTAssertThrowsError(try WordCommentExporter.preview(source: notDocx, plan: margins)) {
            XCTAssertEqual($0 as? DocxCommentWriter.Failure, .notADocx)
        }
        let output = scratch.appending(path: "out.docx")
        XCTAssertThrowsError(try WordCommentExporter.export(source: notDocx, plan: margins, includedIds: ["a"], author: "", to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no half file is left")
    }

    // MARK: What the sheet says

    func testTheSheetStateForAWordDocumentHasNoPagesAndSaysEachSpotInWords() {
        let margins = plan(
            entry("a", sentence: "S one.", words: "First"), entry("b", sentence: "S two.", words: "Second"),
            entry("c", sentence: "S three.", words: "Third"), entry("d", sentence: "S four.", words: "Fourth"),
            entry("e", sentence: "S five.", words: "", status: .transcriptPending))
        let state = PDFCommentExportState(
            plan: margins,
            spots: ["a": .wordSentence(whole: true), "b": .wordSentence(whole: false), "c": .wordParagraph, "d": .wordFirstParagraph],
            document: .word)
        XCTAssertEqual(state.rows.map(\.id), ["a", "b", "c", "d", "e"], "the order of the text, with no pages to sort by")
        XCTAssertEqual(state.rows.map(\.pageLabel), [nil, nil, nil, nil, nil])
        XCTAssertEqual(state.rows.map(\.status.words), [
            "On its sentence", "On the start of its sentence", "On its paragraph, no exact sentence",
            "On the first paragraph, no exact spot", "Left out: transcript not ready yet",
        ])
        XCTAssertEqual(state.includedCount, 4)
        XCTAssertEqual(state.buttonTitle, "Export 4 comments")
        XCTAssertEqual(PDFCommentExportState.Document.word.sheetTitle, "Word document with your Margins")
    }

    func testAMarginNotPlacedYetIsNeverSaidToBeOnAPageInAWordDocument() {
        let loading = PDFCommentExportState(plan: plan(entry("a", sentence: "S.", words: "x")), spots: nil, document: .word)
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertEqual(loading.rows[0].status.words, "On the first paragraph, no exact spot")
        XCTAssertFalse(loading.rows.map(\.status.words).contains { $0.contains("page") })
    }

    func testTheWordSheetsWordsAndFileNameTable() {
        let word = PDFCommentExportState.Document.word
        XCTAssertEqual(PDFCommentExportState.writeFailedMessage(document: word), "Couldn't make the copy. Your Margins and the Word document are unchanged.")
        XCTAssertEqual(PDFCommentExportState.unreadableMessage(document: word), "Couldn't read this Word document. Your Margins and the Word document are unchanged.")
        XCTAssertTrue(PDFCommentExportState.leadLine(title: "Essay", document: word).contains("Word comment"))
        XCTAssertEqual(PDFCommentExportState.leadLine(title: "Essay"), PDFCommentExportState.leadLine(title: "Essay", document: .pdf))
        for (title, expected) in [
            ("Essay", "Essay (with Margins).docx"),
            ("Week 3: Sleep/Memory", "Week 3 Sleep Memory (with Margins).docx"),
            ("  \u{200B} ", "Word document (with Margins).docx"),
            ("", "Word document (with Margins).docx"),
            (".hidden", "hidden (with Margins).docx"),
            ("Café", "Café (with Margins).docx"),
        ] {
            XCTAssertEqual(PDFCommentExportFileName.make(title: title, document: word), expected, title.debugDescription)
        }
        XCTAssertEqual(PDFCommentExportFileName.make(title: ""), "PDF (with Margins).pdf", "the PDF name is unchanged")
        XCTAssertEqual(PDFCommentExportFileName.make(title: String(repeating: "a", count: 300), document: word).count, 120 + " (with Margins).docx".count)
    }
}
