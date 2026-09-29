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

    func testV2ReadsTheAppendixSentenceThatFollowsTheReferences() {
        // #220 T4 on aa22dc4: the appendix's first sentence was taken as a reference,
        // so "References skipped." played twice and then "uation pipeline".
        let entries = [
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "Tianyi Zhang, Varsha Kishore, Felix Wu, et al. 2020.", role: .body),
            StructuredDocumentLine(text: "BERTScore: Evaluating Text Generation with BERT.", role: .body),
            StructuredDocumentLine(text: "Tony Z. Zhao, Eric Wallace, Shi Feng, et al. 2021. Cali-", role: .body),
            StructuredDocumentLine(text: "brate Before Use. arXiv preprint.", role: .body),
            StructuredDocumentLine(text: "Wayne Xin Zhao, Kun Zhou, Junyi Li, et al. 2025. A", role: .body),
            StructuredDocumentLine(text: "Survey of Large Language Models. arXiv preprint.", role: .body),
        ]
        // Order 1 (host): the appendix headings come out as body lines, "A Appendix".
        var hostOrder = entries + [
            StructuredDocumentLine(text: "A Appendix", role: .body),
            StructuredDocumentLine(text: "A.1 Large Language Models Used", role: .body),
            StructuredDocumentLine(text: "The following LLMs were integrated into the eval-", role: .body),
            StructuredDocumentLine(text: "uation pipeline:", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&hostOrder)
        XCTAssertEqual(Array(hostOrder.map(\.role).suffix(4)), [.body, .body, .body, .body])
        // Order 2 (simulator): headings, then more entries, then the appendix sentence.
        var deskOrder = entries + [
            StructuredDocumentLine(text: "Appendix", role: .heading, level: 1),
            StructuredDocumentLine(text: "Large Language Models Used", role: .heading, level: 2),
            StructuredDocumentLine(text: "Max Schäfer, Sarah Nadi, Aryaz Eghbali, et al. 2024.", role: .body),
            StructuredDocumentLine(text: "An Empirical Evaluation. IEEE Transactions on Software", role: .body),
            StructuredDocumentLine(text: "Engineering, 50(1):85-", role: .body),
            StructuredDocumentLine(text: "The following LLMs were integrated into the eval-", role: .body),
            StructuredDocumentLine(text: "uation pipeline:", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&deskOrder)
        XCTAssertEqual(Array(deskOrder.map(\.role).suffix(7)), [.heading, .heading, .reference, .reference, .reference, .body, .body])
    }

    func testV2KeepsSkippingReferenceEntriesPrintedAfterTheAppendixHeading() {
        // #220 T4: on a two-column reference page PDFKit reads "Appendix" between the
        // columns, and the second column's entries were read aloud as body text.
        var lines = [
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "Marah Abdin, Sam Ade Jacobs, et al. 2024. Phi-3 Technical", role: .body),
            StructuredDocumentLine(text: "Report. arXiv preprint.", role: .body),
            StructuredDocumentLine(text: "[2] B. Brown. Sleep and memory. Nature, 2011.", role: .body),
            StructuredDocumentLine(text: "Usman Anwar, Abulhair Saparov, et al. 2024. Foundational", role: .body),
            StructuredDocumentLine(text: "Challenges. arXiv preprint.", role: .body),
            StructuredDocumentLine(text: "Xiao Pu, Mingqi Gao, and Xiaojun Wan. 2023. Summarization", role: .body),
            StructuredDocumentLine(text: "is (Almost) Dead. arXiv preprint.", role: .body),
            StructuredDocumentLine(text: "Appendix", role: .heading, level: 1),
            StructuredDocumentLine(text: "Large Language Models Used", role: .heading, level: 2),
            StructuredDocumentLine(text: "Max Schäfer, Sarah Nadi, Aryaz Eghbali, et al. 2024.", role: .body),
            StructuredDocumentLine(text: "An Empirical Evaluation of Unit Test Generation. IEEE", role: .body),
            StructuredDocumentLine(text: "Transactions on Software Engineering, 50(1):85-105.", role: .body),
            StructuredDocumentLine(text: "C Spearman. 2010. The proof and measurement of association.", role: .body),
            StructuredDocumentLine(text: "We used three models for the evaluation pipeline.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.reference, .reference, .reference, .reference, .reference, .reference, .reference, .reference,
                                          .heading, .heading, .reference, .reference, .reference, .reference, .body])
    }

    func testV2MarksOnlyLineEndHyphensThatSplitOneWord() {
        // #220 T4: "agree-" + "ment" was spoken "agree, ment". A compound broken at its
        // hyphen ("open-" + "ended") must keep the hyphen.
        var lines = [
            StructuredDocumentLine(text: "Adjustable agree-", role: .body),
            StructuredDocumentLine(text: "ment is open-", role: .body),
            StructuredDocumentLine(text: "ended with chain-of-", role: .body),
            StructuredDocumentLine(text: "thought and Mixtral-", role: .body),
            StructuredDocumentLine(text: "8x7B.", role: .body),
        ]
        PDFStructuredTextExtractor.markSoftHyphens(&lines) { Set($0).intersection(["agreement"]) }
        XCTAssertEqual(lines.map(\.endsWithSoftHyphen), [true, false, false, false, false])
        // The real dictionary knows the difference.
        XCTAssertEqual(PDFStructuredTextExtractor.dictionaryWords(["agreement", "openended"]), ["agreement"])
    }

    func testV2SilencesSuperscriptCitationsButKeepsSubscripts() throws {
        // #220 audit 3: real imports never marked superscript citations, so "aptitude,1"
        // was spoken with its number. A lowered subscript ("CO2") must stay.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7)]
        let text = NSMutableAttributedString(string: "Reasoning and the aptitude,", attributes: body)
        text.append(NSAttributedString(string: "1", attributes: small))
        text.append(NSAttributedString(string: " is revised, and CO", attributes: body))
        text.append(NSAttributedString(string: "2", attributes: small.merging([.baselineOffset: -3]) { $1 }))
        text.append(NSAttributedString(string: " levels rose in every cohort we studied.", attributes: body))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            text.draw(at: CGPoint(x: 60, y: 80))
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(document), ["Reasoning and the aptitude, is revised, and CO2 levels rose in every cohort we studied."])
    }

    func testV2SkipsTheAuthorNotesAtTheBottomOfPageOne() throws {
        // #250 on arXiv 2608.09666: page 1's bulleted author notes ("• Corresponding
        // author.", "• Email: ...") were read in the middle of an Introduction sentence.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Existing evaluation methods rely on fixed benchmarks and" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: body)
            ("often produce single numerical scores as their outcomes." as NSString).draw(at: CGPoint(x: 60, y: 94), withAttributes: body)
            ("• Corresponding author." as NSString).draw(at: CGPoint(x: 60, y: 690), withAttributes: small)
            ("• Email: someone@example.edu" as NSString).draw(at: CGPoint(x: 60, y: 700), withAttributes: small)
            ("• The authors are with S-Lab, Example Technological University;" as NSString).draw(at: CGPoint(x: 60, y: 710), withAttributes: small)
            ("and the Example Institute of Science." as NSString).draw(at: CGPoint(x: 72, y: 720), withAttributes: small)
            context.beginPage()
            ("The second page continues the body text of the paper here." as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: body)
            ("• A bulleted point in body text stays, as a list item on page two." as NSString).draw(at: CGPoint(x: 60, y: 94), withAttributes: body)
        }
        let spoken = StructuredDocumentSpeech.spokenLines(
            try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        ).joined(separator: " ")
        for unheard in ["Corresponding author", "Email", "S-Lab", "Example Institute"] {
            XCTAssertFalse(spoken.contains(unheard), unheard)
        }
        XCTAssertTrue(spoken.contains("often produce single numerical scores"))
        XCTAssertTrue(spoken.contains("A bulleted point in body text stays"))
    }

    func testV2SkipsFootnoteTextAtTheFootOfAPage() throws {
        // #250: v2 never gave a line the footnote role, so a page's footnote was read
        // where PDFKit placed it, often between the halves of a body sentence.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let marker: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7)]
        let note: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        let legend: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7)]
        let cited = NSMutableAttributedString(string: "Participants kept a short diary of every session,", attributes: body)
        cited.append(NSAttributedString(string: "1", attributes: marker))
        cited.append(NSAttributedString(string: " and read it back to us weekly.", attributes: body))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("We asked twelve researchers to listen to papers during their commute." as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: body)
            context.beginPage()
            cited.draw(at: CGPoint(x: 60, y: 80))
            ("Most sessions happened before nine in the morning on weekdays." as NSString).draw(at: CGPoint(x: 60, y: 96), withAttributes: body)
            ("Participants said the figures were the hardest part to follow by ear." as NSString).draw(at: CGPoint(x: 60, y: 112), withAttributes: body)
            ("1 The diaries were kept on paper and transcribed later by two of the authors," as NSString).draw(at: CGPoint(x: 60, y: 650), withAttributes: note)
            ("who checked each entry against the recorded session logs." as NSString).draw(at: CGPoint(x: 60, y: 660), withAttributes: note)
            ("3 Samples were collected at three sites in the spring of that year." as NSString).draw(at: CGPoint(x: 60, y: 700), withAttributes: legend)
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertFalse(spoken.contains("diaries were kept"))
        XCTAssertFalse(spoken.contains("checked each entry"))
        XCTAssertTrue(document.segments.contains { $0.role == .footnote })
        XCTAssertTrue(spoken.contains("and read it back to us weekly"))
        XCTAssertTrue(spoken.contains("Most sessions happened before nine"))
        // Small print starting with a number that no body superscript points to stays.
        XCTAssertTrue(spoken.contains("Samples were collected at three sites"))
    }

    func testV2TakesTheArXivSideStampForPageFurniture() {
        // #220 T4 and #162: "arXiv:2607.28282v1 [cs.CL] 30 Jul 2026", printed rotated
        // in the left margin of every arXiv paper, was read as the first sentence.
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        XCTAssertTrue(PDFStructuredTextExtractor.isSideStamp("arXiv:2607.28282v1 [cs.CL] 30 Jul 2026", bounds: CGRect(x: 21, y: 182, width: 20, height: 340), pageBox: box))
        XCTAssertTrue(PDFStructuredTextExtractor.isSideStamp("Downloaded from journals.example.org", bounds: CGRect(x: 580, y: 200, width: 12, height: 300), pageBox: box))
        XCTAssertFalse(PDFStructuredTextExtractor.isSideStamp("We cite arXiv:2607.28282 in the text.", bounds: CGRect(x: 72, y: 400, width: 468, height: 12), pageBox: box))
        XCTAssertFalse(PDFStructuredTextExtractor.isSideStamp("Short", bounds: CGRect(x: 300, y: 400, width: 10, height: 12), pageBox: box))
    }

    func testV2KeepsFormulaLikeLinesInsideAReferenceList() {
        // #220 corpus check: math-looking titles in a reference list were labelled
        // equations, and "Equation not read. References skipped." alternated 15 times.
        var lines = [
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "[1] A. Writer. Groups of order p^3. J Algebra, 2020.", role: .body),
            StructuredDocumentLine(text: "Γ = ⟨a, b | a² = b³⟩", role: .equation),
            StructuredDocumentLine(text: "[2] B. Reader. Presentations. J Algebra, 2021.", role: .body),
            StructuredDocumentLine(text: "[3] C. Listener. Relators. J Algebra, 2022.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.reference, .reference, .reference, .reference, .reference])
    }

    func testV2SkipsAThreeEntryReferenceListAsV1Did() {
        // #220 audit 4: v1 cut a list of three dated entries; v2 needed four and read them.
        var lines = [
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "[1] A. Writer. Reading and listening. J Examples, 2020.", role: .body),
            StructuredDocumentLine(text: "[2] B. Reader. Commutes and attention. J Examples, 2021.", role: .body),
            StructuredDocumentLine(text: "[3] C. Listener. Audio papers. J Examples, 2022.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.reference, .reference, .reference, .reference])
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
