import XCTest
import PDFKit
import UIKit
import SessionKit
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

final class PDFStructuredTextExtractorTests: XCTestCase {

    func testPDFDownloadDatesDoNotChangePreparedTextIdentityButBodyDatesDo() throws {
        func extracted(stamp: String, body: String) throws -> String {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                context.beginPage()
                (stamp as NSString).draw(at: CGPoint(x: 30, y: 25), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                (body as NSString).draw(in: CGRect(x: 40, y: 200, width: 520, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
            return try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        }
        let body = "Research findings. The experiment began on 2026-09-01. Its results are meaningful."
        let first = try extracted(stamp: "Downloaded on 2026-09-21", body: body)
        let second = try extracted(stamp: "Downloaded on 2026-09-22", body: body)
        XCTAssertFalse(first.contains("Downloaded"))
        XCTAssertEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(second))
        let changed = try extracted(stamp: "Downloaded on 2026-09-22", body: body.replacingOccurrences(of: "2026-09-01", with: "2026-09-02"))
        XCTAssertNotEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(changed))
        let quote = "Its results are meaningful."
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: quote)
        let resolution = PortableArticleAnchorResolver.resolve(anchor: anchor, in: second, expectedExactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(first))
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertNotNil(resolution.localStartChar)
        XCTAssertFalse(PDFStructuredTextExtractor.isDownloadStamp("The dataset was downloaded on 2026-09-22 for our experiment."))
    }

    func testDownloadStampSharingAFooterLineWithThePageNumberIsNotRead() throws {
        // #162: PDFKit merges "Downloaded on …" and the page number on one baseline.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let footer: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let data = renderer.pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("Part \(page): Why listen with a pencil" as NSString).draw(
                    in: CGRect(x: 72, y: 100, width: 468, height: 400),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                ("Downloaded on 25 September 2026" as NSString).draw(at: CGPoint(x: 72, y: 740), withAttributes: footer)
                ("\(page)" as NSString).draw(at: CGPoint(x: 530, y: 740), withAttributes: footer)
            }
        }
        let markdown = try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        XCTAssertFalse(markdown.contains("Downloaded"), markdown)
        XCTAssertTrue(markdown.contains("Why listen with a pencil"))

        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 25 September 2026 3"))
        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 2026-09-21 Page 3 of 12"))
        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("iv Downloaded on 25 September 2026"))
        XCTAssertFalse(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 25 September 2026 3 times by readers"))
    }

    // MARK: Extraction v2 (C1 M3)

    func testV2ReadsTheAppendixAfterAnAuthorYearReferenceList() {
        // v1 cut everything after the references heading (#215) and missed author-year lists.
        var lines = [
            StructuredDocumentLine(text: "Discussion", role: .heading, level: 2),
            StructuredDocumentLine(text: "The effect held.", role: .body),
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "Agarwal A, Halvorson LM (2005) Pituitary peptides. J Neurosci 72:451.", role: .body),
            StructuredDocumentLine(text: "Abdul-Hay, S. O., and Thatcher, G. R. (2009). Selective modulation.", role: .body),
            StructuredDocumentLine(text: "[3] C. Writer. Reading and listening. 2020.", role: .body),
            StructuredDocumentLine(text: "Lee K, Park J (2019) Sleep. Nature 1:2.", role: .body),
            StructuredDocumentLine(text: "Appendix A", role: .heading, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.heading, .body, .reference, .reference, .reference, .reference, .reference, .heading, .body])
    }

    func testV2DoesNotTakeAProseMentionOfReferencesForAList() {
        var lines = [
            StructuredDocumentLine(text: "References", role: .body),
            StructuredDocumentLine(text: "are listed at the end of each chapter, as in earlier editions.", role: .body),
            StructuredDocumentLine(text: "The method is described below.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.body, .body, .body])
    }

    func testV2RecognisesTitlePageAuthorsAndTableCaptions() {
        XCTAssertTrue(PDFStructuredTextExtractor.looksLikeAuthorList("Ada Example1, Ben Sample2 and C. D. Third*"))
        XCTAssertFalse(PDFStructuredTextExtractor.looksLikeAuthorList("1Department of Ecology, University of Lausanne, CH-1015 Lausanne"))
        XCTAssertFalse(PDFStructuredTextExtractor.looksLikeAuthorList("We asked twelve researchers to listen to papers."))
        XCTAssertTrue(PDFStructuredTextExtractor.isTableCaption("Table 3"))
        XCTAssertTrue(PDFStructuredTextExtractor.isTableCaption("Table 2. Baseline characteristics"))
        XCTAssertFalse(PDFStructuredTextExtractor.isTableCaption("Table 2 shows the results."))
        XCTAssertTrue(PDFStructuredTextExtractor.isFigureCaption("Fig. 3 (a) Survival by arm."))
        XCTAssertTrue(PDFStructuredTextExtractor.isFigureCaption("FIGURE 1. Study design"))
        XCTAssertFalse(PDFStructuredTextExtractor.isFigureCaption("Figure 3 shows a decline."))
    }

    func testV2JoinsTheFragmentsOfAMultiLineEquationButNotProse() {
        var lines = [
            StructuredDocumentLine(text: "𝑓(𝑥) = ∑ 𝑎ᵢ", role: .equation, pageIndex: 1),
            StructuredDocumentLine(text: "(3)", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "𝑔(𝑥) = ∫ 𝑓", role: .equation, pageIndex: 1),
            StructuredDocumentLine(text: "where both terms", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "ℎ = 𝑓 ∘ 𝑔", role: .equation, pageIndex: 1),
        ]
        PDFStructuredTextExtractor.joinEquationFragments(&lines)
        XCTAssertEqual(lines.map(\.role), [.equation, .equation, .equation, .body, .equation])
    }

    // MARK: C1 M3: written Margins on a PDF imported under v1 (I13 rule 1d/1e)

    /// Four pages with a running head and page numbers, a sentence that crosses the
    /// page 1-2 break, and a numbered reference list.
    private func listeningStudyPDF() throws -> PDFDocument {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Listening Study"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16)]
        let pages: [[(String, [NSAttributedString.Key: Any])]] = [
            [("Methods", heading), ("We asked twelve researchers to listen to papers during their commute.", body),
             ("Each participant listened for four weeks and kept a short diary of sessions.", body),
             ("Across all participants the effect held", body)],
            [("across cohorts and across the four weeks of the study without exception.", body),
             ("Listening was slower than reading but fitted into time that reading could not use.", body)],
            [("Results", heading), ("Most sessions happened before nine in the morning on weekdays.", body),
             ("Participants said the figures were the hardest part to follow by ear.", body)],
            [("Participants asked for tables to be announced rather than read aloud.", body),
             ("References", heading), ("[1] A. Writer. Reading and listening. J Examples, 2020.", body),
             ("[2] B. Reader. Commutes and attention. J Examples, 2021.", body),
             ("[3] C. Listener. Audio papers. J Examples, 2022.", body),
             ("[4] D. Hearer. Spoken margins. J Examples, 2023.", body)],
        ]
        let data = renderer.pdfData { context in
            for (index, lines) in pages.enumerated() {
                context.beginPage()
                ("Journal of Listening Studies 12 (2026)" as NSString).draw(at: CGPoint(x: 60, y: 30), withAttributes: body)
                var y: CGFloat = 90
                for (text, attributes) in lines {
                    (text as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: attributes)
                    y += 24
                }
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: 300, y: 750), withAttributes: body)
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    /// Imports the PDF under v1, writes Margins on `marginWords`, re-imports it under v2.
    private func reimportUnderV2(marginWords: [String]) throws -> (sameItem: Bool, marginsOpenAtTheirWords: Bool, v1TextKept: Bool) {
        let pdf = try listeningStudyPDF()
        let path = FileManager.default.temporaryDirectory.appending(path: "c1-m3-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Listening%20Study.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Listening Study"),
            text: try PDFStructuredTextExtractor.markdown(from: pdf),
            contentFormat: .markdown
        ))
        let v1Text = try XCTUnwrap(v1.text)
        let session = Session(id: "session-m3", itemId: v1.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: v1.id, position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(session)
        for (index, words) in marginWords.enumerated() {
            let start = v1Text.distance(from: v1Text.startIndex, to: try XCTUnwrap(v1Text.range(of: words), words).lowerBound)
            try store.saveInterjection(Interjection(
                id: "margin-\(index)", itemId: v1.id, sessionId: session.id, targetType: .item, targetId: v1.id,
                createdAt: Date(timeIntervalSince1970: Double(index)), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: start, endChar: start + words.count, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "Margin \(index)", status: "active"
            ))
        }

        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: try XCTUnwrap(PDFStructuredTextExtractor.itemTitle(for: pdf, structured: document))),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)

        let item = try store.loadItem(id: v1.id)
        let characters = Array(item.text ?? "")
        let margins = try store.loadInterjections(sessionId: session.id).sorted { $0.id < $1.id }
        let openAtTheirWords = margins.count == marginWords.count && margins.enumerated().allSatisfy { index, margin in
            margin.anchor.endChar <= characters.count
                && String(characters[margin.anchor.startChar..<margin.anchor.endChar]) == marginWords[index]
        }
        return (reimported.id == v1.id, openAtTheirWords, item.text == v1Text)
    }

    func testMarginsOnAPDFImportedUnderV1OpenAtTheSameWordsAfterV2() throws {
        let moved = try reimportUnderV2(marginWords: [
            "We asked twelve researchers",          // start
            "Most sessions happened",               // middle
            "tables to be announced",               // end
        ])
        XCTAssertTrue(moved.sameItem, "every Margin lands on the same words, so the item moves to v2")
        XCTAssertFalse(moved.v1TextKept)
        XCTAssertTrue(moved.marginsOpenAtTheirWords)
    }

    func testAPDFStaysOnV1WhenAMarginsWordsChangeUnderV2() throws {
        // v1 keeps page 1's page number inside the sentence that crosses the break;
        // v2 also keeps the next page's running head there, so the words differ.
        let stayed = try reimportUnderV2(marginWords: [
            "We asked twelve researchers",
            "the effect held\n1\nacross cohorts",
            "tables to be announced",
        ])
        XCTAssertFalse(stayed.sameItem, "the v2 text becomes its own edition")
        XCTAssertTrue(stayed.v1TextKept)
        XCTAssertTrue(stayed.marginsOpenAtTheirWords)
    }
}
