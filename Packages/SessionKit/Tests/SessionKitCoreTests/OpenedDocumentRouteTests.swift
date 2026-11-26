import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2997 PR 5: which files Open In and AirDrop take, and what a listener reads for the ones it does not.
final class OpenedDocumentRouteTests: XCTestCase {
    private func route(_ name: String, plainText: Bool = true) -> OpenedDocumentRoute? {
        OpenedDocumentRoute.route(forFileNamed: name, isPlainText: plainText)
    }

    func testTheFourTranscriptTypesGoToTheTranscriptRuleWhateverTheCaseOrDots() {
        let rows = [
            "meeting.vtt", "meeting.srt", "meeting.docx", "meeting.txt",
            "MEETING.VTT", "Budget sync.Srt", "Weekly 2026.03.04.DOCX", "zoom_0.txt",
            "a.b.c.txt", ".txt.vtt", "  spaced name .txt",
        ]
        for name in rows { XCTAssertEqual(route(name, plainText: false), .transcriptRule, name) }
    }

    func testMarkdownGoesToTheTextImport() {
        for name in ["notes.md", "notes.MD", "Read me.markdown", "x.y.md"] {
            XCTAssertEqual(route(name), .text, name)
        }
    }

    func testAnotherPlainTextTypeIsRefusedWithItsOwnSentenceNamingTheFile() {
        for name in ["table.csv", "run.log", "main.swift", "notes.text", "page.html", "README"] {
            guard case .unsupported(let message)? = route(name) else { return XCTFail("\(name) was not refused") }
            XCTAssertEqual(message.kind, .unsupportedType, name)
            XCTAssertEqual(message.fileName, name, name)
            XCTAssertEqual(
                message.errorDescription,
                "Spoken Margins can't add \u{201C}\(name)\u{201D}. It adds meeting transcripts (.vtt, .srt, .docx, .txt) and text or Markdown files.",
                name)
        }
    }

    func testAFileThatIsNotPlainTextKeepsItsOwnRoute() {
        for name in ["a.spokenmargins", "paper.pdf", "book.epub", "episode.mp3", "edition.json", "photo.heic", "noextension", ""] {
            XCTAssertNil(route(name, plainText: false), name)
        }
    }

    func testAnOddNameStillReadsAsOneLineInTheSentence() {
        guard case .unsupported(let message)? = route("a\nb\tc.csv") else { return XCTFail("not refused") }
        XCTAssertFalse((message.errorDescription ?? "").contains("\n"))
    }

    func testAVeryLongNameIsCutInTheSentenceNotInTheRule() {
        let name = String(repeating: "n", count: 200) + ".csv"
        guard case .unsupported(let message)? = route(name) else { return XCTFail("not refused") }
        XCTAssertEqual(message.fileName, name)
        XCTAssertLessThan((message.errorDescription ?? "").count, 200)
    }

    /// Open In and a pick from Files read the same four extensions, so a file is never a transcript in one and not the other.
    func testOpenInReadsTheSameTranscriptExtensionsAsAPickFromFiles() {
        XCTAssertEqual(OpenedDocumentRoute.transcriptExtensions, TranscriptPickImport.candidateExtensions)
    }
}
