import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitEPUB
import SessionKitPersistence
import SessionKitTestInputs

/// #4594: a Word document picked in + › Files becomes a Library item. Every case reads a real `.docx` from
/// `Contracts/fixtures/word/`, which `scripts/make-word-fixtures.py` writes from public-domain text.
final class WordDocumentImportTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try TestInputs.data(.contracts, "fixtures/word/\(name)")
    }

    private func read(_ name: String) throws -> ImportedSourceText {
        let data = try fixture(name)
        return try WordDocumentImport.read(data: data, fileName: name)
    }

    private func item(_ name: String) throws -> PreparedObsidianImport {
        let imported = try read(name)
        return try SourceFileItemBuilder.prepare(
            imported, fileURL: URL(fileURLWithPath: "/picked/\(name)"), itemId: "word-\(name)",
            createdAt: Date(timeIntervalSince1970: 1_000))
    }

    private func bodyText(_ name: String) throws -> String {
        let prepared = try item(name)
        return try XCTUnwrap(prepared.item.text)
    }

    // MARK: The item an import makes

    func testPlainParagraphsBecomeAnItemTitledFromTheDocumentsProperties() throws {
        let prepared = try item("plain-paragraphs.docx")
        XCTAssertEqual(prepared.item.title, "The Gettysburg Address")
        XCTAssertEqual(prepared.item.mediaType, "text")
        XCTAssertEqual(prepared.item.externalReference, "plain-paragraphs.docx")
        XCTAssertEqual(prepared.item.externalReferenceType, "file")
        XCTAssertTrue(try XCTUnwrap(prepared.item.text).hasPrefix("Four score and seven years ago our fathers brought forth on this continent"))
        XCTAssertEqual(try XCTUnwrap(prepared.item.text).components(separatedBy: "\n\n").count, 3, "one paragraph each, a blank line between")
        XCTAssertNil(prepared.structuredDocument)
    }

    func testHeadingsAreChaptersAndListItemsAreTheirOwnLines() throws {
        let prepared = try item("headings-and-lists.docx")
        XCTAssertEqual(prepared.item.title, "headings-and-lists", "no title in the properties: the file name, as the issue asks")
        let map = try XCTUnwrap(prepared.listeningMap)
        XCTAssertEqual(map.chapters.map(\.title), ["Economy", "Where I Lived, and What I Lived For", "Sounds"])
        let text = try XCTUnwrap(prepared.item.text)
        // The document's title folds into the first chapter, as a Markdown file's lone `#` does (#1435); the rest start
        // at their headings.
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertTrue(text.hasPrefix("Walden\n\nEconomy\n\n"))
        for chapter in map.chapters.dropFirst() {
            let start = text.index(text.startIndex, offsetBy: chapter.startChar)
            XCTAssertTrue(text[start...].hasPrefix(chapter.title), "\(chapter.title) starts at its heading")
        }
        XCTAssertTrue(text.contains("\n\nFood\n\nClothing\n\nFuel\n\n"))
    }

    func testAHeadingStyleNamedInAnotherLanguageIsStillAHeading() throws {
        let prepared = try item("localized-headings.docx")
        XCTAssertEqual(prepared.listeningMap?.chapters.map(\.title), ["Erstes Kapitel", "Zweites Kapitel"])
    }

    /// The text is the document's words, not Markdown: nothing is stripped or dropped for looking like markup.
    func testLinesThatLookLikeMarkdownStayAsWritten() throws {
        let text = try bodyText("markdown-lookalikes.docx")
        XCTAssertTrue(text.contains("# of days in the woods"), text)
        XCTAssertTrue(text.contains("- a dash that opens a line"), text)
        XCTAssertTrue(text.contains("Timestamps were never kept at Walden."), text)
        XCTAssertTrue(text.contains("**Bold** words and a [bracket](like this) stay as text."), text)
    }

    // MARK: Neighbouring inputs

    func testATablesCellsAreRead() throws {
        let text = try bodyText("table.docx")
        for cell in ["Boards", "$8.03½", "Refuse shingles for roof and sides", "Two second-hand windows with glass", "2.43"] {
            XCTAssertTrue(text.contains(cell), "\(cell) in \(text)")
        }
        XCTAssertTrue(text.hasSuffix("twelve and a half cents."))
    }

    func testTrackedChangesReadAsAccepted() throws {
        let text = try bodyText("tracked-changes.docx")
        XCTAssertTrue(text.contains("our fathers brought forth"), text)
        XCTAssertFalse(text.contains("grandfathers"), "deleted text is not read")
        XCTAssertEqual(text.components(separatedBy: "We are met on a great battle-field").count - 1, 1, "moved text is read once, where it went")
        XCTAssertTrue(text.contains("civil war. We are met"))
    }

    func testCommentsAreNotReadButStayInTheFile() throws {
        let data = try fixture("comments.docx")
        let text = try bodyText("comments.docx")
        XCTAssertTrue(text.hasPrefix("The world will little note"))
        XCTAssertFalse(text.contains("reviewer comment"))
        XCTAssertNotNil(data.range(of: Data("word/comments.xml".utf8)), "the original keeps its comments part")
    }

    func testFootnotesAreNotReadInTheBody() throws {
        let text = try bodyText("footnotes.docx")
        XCTAssertEqual(text, "I went to the woods because I wished to live deliberately. I wanted to live deep and suck out all the marrow of life.")
    }

    func testSmartQuotesAndUnicodeSurvive() throws {
        let prepared = try item("unicode.docx")
        XCTAssertEqual(prepared.item.title, "Smart quotes and Unicode")
        let text = try XCTUnwrap(prepared.item.text)
        for piece in ["truth universally acknowledged", "Café", "naïve", "Ångström", "春眠不覺曉", "שלום"] {
            XCTAssertTrue(text.contains(piece), "\(piece) in \(text)")
        }
    }

    func testATextBoxIsReadOnceAndItsParagraphIsKeptWhole() throws {
        let text = try bodyText("text-box.docx")
        XCTAssertEqual(text.components(separatedBy: "Inside the box.").count - 1, 1, text)
        XCTAssertTrue(text.contains("After the box, same paragraph."), text)
        XCTAssertTrue(text.hasPrefix("Before the box."))
    }

    func testAPlaceholderTitleFallsBackToTheFileName() throws {
        let prepared = try item("placeholder-title.docx")
        XCTAssertEqual(prepared.item.title, "placeholder-title")
    }

    // MARK: Refusals: a plain sentence, and nothing to add

    func testFilesThatCantBeReadAreRefusedWithTheirOwnReason() throws {
        let cases: [(String, WordDocumentImport.Failure)] = [
            ("empty.docx", .empty),
            ("not-a-zip.docx", .notAWordDocument),
            ("old-format.doc", .oldWordFormat),
            ("password-protected.docx", .passwordProtected),
        ]
        for (name, expected) in cases {
            let data = try fixture(name)
            XCTAssertThrowsError(try WordDocumentImport.read(data: data, fileName: name), name) { error in
                XCTAssertEqual(error as? WordDocumentImport.Failure, expected, name)
                let message = ListenerErrorText.message(for: error)
                XCTAssertEqual(message, expected.errorDescription, "\(name) shows its own sentence")
            }
        }
        // A real `.docx` renamed `.doc` is still the old-format sentence: the name says what the listener has.
        let renamed = try fixture("plain-paragraphs.docx")
        XCTAssertThrowsError(try WordDocumentImport.read(data: renamed, fileName: "renamed.doc")) {
            XCTAssertEqual($0 as? WordDocumentImport.Failure, .oldWordFormat)
        }
        // An old `.doc` renamed `.docx` is found by its bytes.
        let old = try fixture("old-format.doc")
        XCTAssertThrowsError(try WordDocumentImport.read(data: old, fileName: "renamed.docx")) {
            XCTAssertEqual($0 as? WordDocumentImport.Failure, .oldWordFormat)
        }
    }

    func testADocumentOverTheCapIsRefusedAsTooLarge() throws {
        let data = try fixture("plain-paragraphs.docx")
        XCTAssertThrowsError(try WordDocumentImport.read(data: data, fileName: "big.docx", maximumDocumentBytes: 200)) {
            XCTAssertEqual($0 as? WordDocumentImport.Failure, .tooLarge)
        }
        XCTAssertNoThrow(try WordDocumentImport.read(data: data, fileName: "big.docx", maximumDocumentBytes: 20_000))
    }

    func testFileAndURLReadsAgreeAndHandBackTheExactBytes() throws {
        let url = try TestInputs.url(.contracts, "fixtures/word/plain-paragraphs.docx")
        let read = try WordDocumentImport.read(url: url)
        XCTAssertEqual(read.original, try Data(contentsOf: url))
        let fromData = try self.read("plain-paragraphs.docx")
        XCTAssertEqual(read.imported.paragraphs, fromData.paragraphs)
        XCTAssertTrue(WordDocumentImport.handles(url))
        XCTAssertTrue(WordDocumentImport.handles(URL(fileURLWithPath: "/a/OLD.DOC")))
        XCTAssertFalse(WordDocumentImport.handles(URL(fileURLWithPath: "/a/notes.md")))
    }

    /// The transcript reader shares the parser: a Word transcript still reads as before.
    func testTheTranscriptTextOfAPlainDocumentIsUnchanged() throws {
        let data = try fixture("plain-paragraphs.docx")
        let text = try DocxPlainText.text(from: data)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(text.hasPrefix("Four score"))
    }

    // MARK: The kept original

    func testTheKeptOriginalIsTheWordFileByteForByteAndReplacesAPDF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("word-original-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ItemOriginalStore(root: root)
        let docx = try fixture("plain-paragraphs.docx")

        let pdfURL = try store.write(Data("%PDF-1.7 earlier".utf8), itemId: "item-1")
        XCTAssertEqual(store.kind(itemId: "item-1"), .pdf)
        let url = try store.write(docx, itemId: "item-1", kind: .docx)
        XCTAssertEqual(url.lastPathComponent, "original.docx")
        XCTAssertEqual(store.url(itemId: "item-1"), url)
        XCTAssertEqual(store.kind(itemId: "item-1"), .docx)
        XCTAssertEqual(try Data(contentsOf: url), docx)
        XCTAssertEqual(store.sha256(itemId: "item-1"), ItemOriginalStore.sha256(of: docx))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path), "an item keeps one original")

        // A quit halfway through a Word write leaves a temporary file that launch cleanup clears, never the original.
        let leftover = url.deletingLastPathComponent().appendingPathComponent("original.docx.\(UUID().uuidString).tmp")
        try Data("half".utf8).write(to: leftover)
        XCTAssertEqual(store.removeInterruptedWrites(olderThan: 0), 1)
        XCTAssertEqual(try Data(contentsOf: url), docx)

        try store.remove(itemId: "item-1")
        XCTAssertNil(store.url(itemId: "item-1"))
        XCTAssertNil(store.kind(itemId: "item-1"))
    }

    /// A Files import stages each picked file in its item's folder and commits it once the item saves, so a batch holds
    /// no bytes (#4338). A staged Word file must commit as `original.docx` and leave the item one original either way.
    func testAStagedWordFileCommitsAsTheDocxOriginalAndAnItemKeepsOneOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("word-staged-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ItemOriginalStore(root: root)
        let docx = try fixture("plain-paragraphs.docx")
        let picked = root.appendingPathComponent("picked/Essay.docx")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try docx.write(to: picked)
        let folder = try XCTUnwrap(store.folderURL(itemId: "item-1"))

        try store.write(Data("%PDF-1.7 earlier".utf8), itemId: "item-1")
        let staged = try store.stage(copying: picked, itemId: "item-1", kind: .docx)
        XCTAssertEqual(staged.sha256, ItemOriginalStore.sha256(of: docx))
        XCTAssertEqual(store.kind(itemId: "item-1"), .pdf, "not the original until it is committed")
        let url = try store.commit(staged)
        XCTAssertEqual(url.lastPathComponent, "original.docx")
        XCTAssertEqual(store.kind(itemId: "item-1"), .docx)
        XCTAssertEqual(try Data(contentsOf: url), docx)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["original.docx"])

        let pdfPicked = root.appendingPathComponent("picked/Paper.pdf")
        let pdf = Data("%PDF-1.7 re-imported".utf8)
        try pdf.write(to: pdfPicked)
        try store.commit(try store.stage(copying: pdfPicked, itemId: "item-1"))
        XCTAssertEqual(store.kind(itemId: "item-1"), .pdf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["original.pdf"])
    }
}
