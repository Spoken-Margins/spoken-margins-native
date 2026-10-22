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

    func testV2ReadsEachOutlineHeadingOnceWhereItIsPrinted() throws {
        // #355: outline titles no line matched ("A.1" labels, wrapped headings, run-in
        // headings) were inserted at the top of their page and read, then the printed
        // heading was read again; a bookmark with no printed title at all was read too.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let bold: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("The introduction explains why listening to papers is slower than reading them." as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: body)
            context.beginPage()
            ("A.1 Large Language Models Used" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: bold)
            ("Three models were compared on the same set of forty prompts." as NSString).draw(at: CGPoint(x: 60, y: 140), withAttributes: body)
            ("4.3 Handling Multiple Evaluations and" as NSString).draw(at: CGPoint(x: 60, y: 180), withAttributes: bold)
            ("Agreement Thresholds" as NSString).draw(at: CGPoint(x: 60, y: 196), withAttributes: bold)
            ("Each answer was scored twice and disagreements were settled." as NSString).draw(at: CGPoint(x: 60, y: 216), withAttributes: body)
            ("Light stimulation: flashes were delivered full-field to one eye." as NSString).draw(at: CGPoint(x: 60, y: 256), withAttributes: body)
            context.beginPage()
            ("These notes list every prompt used in the study, in the order given." as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: body)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = PDFOutline()
        for (title, pageIndex) in [("Large Language Models Used", 1), ("Handling Multiple Evaluations and Agreement Thresholds", 1),
                                   ("Light stimulation", 1), ("Supplementary Notes", 2)] {
            let entry = PDFOutline()
            entry.label = title
            entry.destination = PDFDestination(page: try XCTUnwrap(pdf.page(at: pageIndex)), at: CGPoint(x: 60, y: 700))
            root.insertChild(entry, at: root.numberOfChildren)
        }
        pdf.outlineRoot = root

        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        for title in ["Large Language Models Used", "Handling Multiple Evaluations and", "Light stimulation"] {
            XCTAssertEqual(spoken.components(separatedBy: title).count - 1, 1, "\(title) is read once")
        }
        XCTAssertFalse(spoken.contains("Supplementary Notes"), "a bookmark with no printed title isn't read")
        let characters = Array(document.text)
        let headings = document.segments.filter { $0.role == .heading }.map { String(characters[$0.range.start..<$0.range.end]) }
        XCTAssertEqual(headings, ["A.1 Large Language Models Used", "4.3 Handling Multiple Evaluations and Agreement Thresholds"])
        XCTAssertEqual(document.outline?.map(\.title), ["Light stimulation", "Supplementary Notes"], "chapter anchors only")
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: document, title: "Paper", itemId: "item"))
        XCTAssertEqual(Array(map.chapters.map(\.title).suffix(4)), [
            "A.1 Large Language Models Used", "4.3 Handling Multiple Evaluations and Agreement Thresholds",
            "Light stimulation", "Supplementary Notes",
        ])
    }

    func testV2ReadsAnOutlineTitleStartingWithLLMOnceAtItsNumberedHeading() throws {
        // #355 on arXiv 2608.09666: the outline entry "LLM as a Judge" didn't match the
        // printed "2.2 LLM as a Judge" (the label stripper took "LLM" for a roman numeral),
        // so the title was inserted at the top of page 2 and read before "2 Related Work",
        // then read again at 2.2 as body text. Same outline shape as the paper.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let bold: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("1 Introduction" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: bold)
            ("Evaluating generative models usually means sampling hundreds of outputs." as NSString).draw(at: CGPoint(x: 60, y: 140), withAttributes: body)
            ("We ask whether an agent can choose what to probe next instead." as NSString).draw(at: CGPoint(x: 60, y: 154), withAttributes: body)
            context.beginPage()
            ("2 Related Work" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: bold)
            ("2.1 Visual Generation and Evaluation" as NSString).draw(at: CGPoint(x: 60, y: 140), withAttributes: bold)
            ("Benchmarks use fixed test sets and scoring pipelines." as NSString).draw(at: CGPoint(x: 60, y: 160), withAttributes: body)
            ("2.2 LLM as a Judge" as NSString).draw(at: CGPoint(x: 60, y: 200), withAttributes: bold)
            ("Language models now grade the answers of other models." as NSString).draw(at: CGPoint(x: 60, y: 220), withAttributes: body)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = PDFOutline()
        func entry(_ title: String, _ pageIndex: Int, under parent: PDFOutline) throws -> PDFOutline {
            let entry = PDFOutline()
            entry.label = title
            entry.destination = PDFDestination(page: try XCTUnwrap(pdf.page(at: pageIndex)), at: CGPoint(x: 60, y: 700))
            parent.insertChild(entry, at: parent.numberOfChildren)
            return entry
        }
        _ = try entry("Introduction", 0, under: root)
        let related = try entry("Related Work", 1, under: root)
        _ = try entry("Visual Generation and Evaluation", 1, under: related)
        _ = try entry("LLM as a Judge", 1, under: related)
        pdf.outlineRoot = root

        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertEqual(spoken.components(separatedBy: "LLM as a Judge").count - 1, 1, "read once")
        let judge = try XCTUnwrap(spoken.range(of: "2.2 LLM as a Judge"), "read with its number, where it is printed")
        let pageOneBody = try XCTUnwrap(spoken.range(of: "probe next instead."))
        let sectionTwoOneBody = try XCTUnwrap(spoken.range(of: "scoring pipelines."))
        XCTAssertGreaterThan(judge.lowerBound, pageOneBody.upperBound, "not before page 1's body")
        XCTAssertGreaterThan(judge.lowerBound, sectionTwoOneBody.upperBound, "after section 2.1")
        let characters = Array(document.text)
        let headings = document.segments.filter { $0.role == .heading }.map { String(characters[$0.range.start..<$0.range.end]) }
        XCTAssertEqual(headings, ["1 Introduction", "2 Related Work", "2.1 Visual Generation and Evaluation", "2.2 LLM as a Judge"])
        XCTAssertNil(document.outline, "every outline entry matched a printed heading")
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

    func testV2MakesNoChaptersFromTheTitleAndAuthorLines() throws {
        // #272 on PMC13305550 (F1000Research): the two lines of a 16 pt title, the
        // fragments of a 13 pt bold author line and a 14 pt "v1" badge each became
        // a chapter, because display type before the abstract was left to the
        // visual-heading rule.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16)]
        let authors: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 13)]
        let badge: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 14)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let prose = [
            "Listening lets researchers take in papers during time that reading cannot use.",
            "We asked twelve researchers to listen to papers during their daily commute.",
            "Each participant kept a short diary of the sessions over four weeks of study.",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Listening to Papers: A Field Study of Researchers" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: title)
            ("on Their Commute" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: title)
            ("Ada Example1" as NSString).draw(at: CGPoint(x: 60, y: 160), withAttributes: authors)
            (", Ben Sample2" as NSString).draw(at: CGPoint(x: 160, y: 160), withAttributes: authors)
            (", Cy Third3" as NSString).draw(at: CGPoint(x: 260, y: 160), withAttributes: authors)
            ("v1" as NSString).draw(at: CGPoint(x: 520, y: 200), withAttributes: badge)
            // At heading size: on the simulator a 9 pt bold "Abstract" wasn't read as a
            // heading, and this test is about the title page, not bold detection.
            ("Abstract" as NSString).draw(at: CGPoint(x: 60, y: 236), withAttributes: heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 256 + CGFloat(offset) * 12), withAttributes: body)
            }
            context.beginPage()
            ("Introduction" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 110 + CGFloat(offset) * 12), withAttributes: body)
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let characters = Array(document.text)
        func text(_ segment: StructuredDocument.Segment) -> String {
            String(characters[segment.range.start..<segment.range.end])
        }

        XCTAssertEqual(document.segments.filter { $0.role == .heading }.map(text), ["Abstract", "Introduction"])
        let titles = document.segments.filter { $0.role == .title }
        XCTAssertEqual(titles.count, 1, "a two-line title is one segment, read once")
        XCTAssertEqual(titles.first.map(text)?.split(whereSeparator: \.isNewline).joined(separator: " "),
                       "Listening to Papers: A Field Study of Researchers on Their Commute")
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertTrue(spoken.contains("Ada Example"), "author names are read (owner, #191)")
        XCTAssertFalse(spoken.contains("v1"))

        // The item keeps v1's title, so a PDF imported under v1 and re-imported under
        // v2 is the same item and the edition guard applies.
        let v1Title = try PDFStructuredTextExtractor.markdown(from: pdf)
            .split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        XCTAssertEqual(PDFStructuredTextExtractor.itemTitle(for: pdf, structured: document), try XCTUnwrap(v1Title))
    }

    /// A page-one title (16 pt bold) over the given lines, then an abstract and a second page.
    private func titlePagePDF(_ top: [(String, CGFloat)], others: [(String, CGPoint, [NSAttributedString.Key: Any])] = []) -> Data {
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let prose = [
            "Listening lets researchers take in papers during time that reading cannot use.",
            "We asked twelve researchers to listen to papers during their daily commute.",
            "Each participant kept a short diary of the sessions over four weeks of study.",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            for (text, y) in top {
                (text as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: title)
            }
            for (text, point, attributes) in others {
                (text as NSString).draw(at: point, withAttributes: attributes)
            }
            ("Abstract" as NSString).draw(at: CGPoint(x: 60, y: 236), withAttributes: heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 256 + CGFloat(offset) * 12), withAttributes: body)
            }
            context.beginPage()
            ("Introduction" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 110 + CGFloat(offset) * 12), withAttributes: body)
            }
        }
    }

    private func headingTexts(_ document: StructuredDocument) -> [String] {
        let characters = Array(document.text)
        return document.segments.filter { $0.role == .heading }.map {
            String(characters[$0.range.start..<$0.range.end]).split(whereSeparator: \.isNewline).joined(separator: " ")
        }
    }

    func testV2ReadsASectionHeadingPrintedOverSeveralLinesAsOneChapter() throws {
        // #1144 (Test Desk T4 on next 6a22bb8): "Automating AI R&D could trigger an" and
        // "intelligence explosion" were two chapters at 13%.
        for lines in [["Automating AI R&D could trigger an", "intelligence explosion"],
                      ["Automating AI R&D could", "trigger an intelligence", "explosion"]] {
            let pdf = try XCTUnwrap(PDFDocument(data: coverThenTitlePagePDF(sectionHeading: lines)))
            let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
            XCTAssertEqual(headingTexts(document), ["Abstract", "Introduction", "Automating AI R&D could trigger an intelligence explosion"],
                           "\(lines.count) lines")
            let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: document, title: "Paper", itemId: "item"))
            XCTAssertEqual(map.chapters.map(\.title), ["Abstract", "Introduction", "Automating AI R&D could trigger an intelligence explosion"])
            XCTAssertEqual(map.chapters.first?.startChar, 0, "the title page starts the first chapter; no Front Matter chapter")
        }
    }

    func testV2KeepsTheItemTitleOfAnUntitledPDFWhoseTitleIsPrintedOverTwoLines() throws {
        // Review of #1144's heading join: with no metadata title and no Abstract label, a
        // two-line printed title is a level-1 heading. Joining it changed `itemTitle`, so a
        // re-imported shared PDF became a new item with its Margins left on the old one.
        let prose = [
            "Listening lets researchers take in papers during time that reading cannot use.",
            "We asked twelve researchers to listen to papers during their daily commute.",
            "Each participant kept a short diary of the sessions over four weeks of study.",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 20)]
            ("Listening to Papers:" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: title)
            ("A Field Study" as NSString).draw(at: CGPoint(x: 60, y: 84), withAttributes: title)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 130 + CGFloat(offset) * 12), withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
            }
            context.beginPage()
            ("Introduction" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 12)])
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 110 + CGFloat(offset) * 12), withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let v1Title = try PDFStructuredTextExtractor.markdown(from: pdf)
            .split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        XCTAssertEqual(v1Title, "Listening to Papers:")
        XCTAssertEqual(PDFStructuredTextExtractor.itemTitle(for: pdf, structured: document), v1Title)
    }

    func testV2StartsTheChaptersAtAnAbstractLabelSetInBodyType() throws {
        // The real paper sets "Abstract" in 12 pt regular, so it is not a heading by its type.
        // The chapter list started with "Front Matter", holding the title page and the abstract.
        let pdf = try XCTUnwrap(PDFDocument(data: coverThenTitlePagePDF(abstractInBodyType: true)))
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        XCTAssertEqual(headingTexts(document), ["Introduction"])
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(
            for: document, title: "What if automating AI R&D triggers an intelligence explosion?", itemId: "item"))
        XCTAssertEqual(map.chapters.map(\.title), ["Abstract", "Introduction"])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
    }

    func testV2ReadsTheTitleOnceHoweverPageTwoRepeatsIt() throws {
        // Page 2's copy of the cover title is front matter whatever its case, spacing or line
        // breaks; a paper without the copy reads the same; the title in later prose is read.
        let rows: [(String, [String], String?, Int)] = [
            ("upper case", ["WHAT IF AUTOMATING AI R&D", "TRIGGERS AN INTELLIGENCE", "EXPLOSION?"], nil, 1),
            ("hyphenated at the break", ["What if automating AI R&D", "triggers an intelli-", "gence explosion?"], nil, 1),
            ("broken elsewhere, double space", ["What  if automating AI R&D", "triggers an intelligence explosion?"], nil, 1),
            ("no repeat on page 2", [], nil, 1),
            ("the title quoted in later prose", ["What if automating AI R&D triggers an", "intelligence explosion?"],
             "We ask what if automating AI R&D triggers an intelligence explosion in this paper.", 2),
        ]
        for (name, repeated, later, expected) in rows {
            let pdf = try XCTUnwrap(PDFDocument(data: coverThenTitlePagePDF(repeatedTitle: repeated, laterProse: later)))
            let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
            let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ").lowercased()
            XCTAssertEqual(spoken.components(separatedBy: "automating ai r&d").count - 1, expected, name)
            XCTAssertTrue(spoken.contains("alan chan"), name)
            XCTAssertEqual(titleSegments(document), ["What if automating AI R&D triggers an intelligence explosion?"], name)
        }
    }

    private func titleSegments(_ document: StructuredDocument) -> [String] {
        let characters = Array(document.text)
        return document.segments.filter { $0.role == .title }.map {
            String(characters[$0.range.start..<$0.range.end]).split(whereSeparator: \.isNewline).joined(separator: " ")
        }
    }

    func testV2ReadsATitleWhoseFirstLineIsShort() throws {
        // #692: title candidates need four or more words, so a short first line was
        // left out of the title, read as a badge, and never spoken; the item title
        // also changed from v1's, so a re-import missed the existing item.
        let authors: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 13)]
        let data = titlePagePDF(
            [("Understanding uncertainty", 90), ("in modern machine learning systems", 110)],
            others: [("Ada Example1, Ben Sample2", CGPoint(x: 60, y: 160), authors)]
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let fullTitle = "Understanding uncertainty in modern machine learning systems"

        XCTAssertEqual(titleSegments(document), [fullTitle], "both printed lines are one title segment")
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertTrue(spoken.contains(fullTitle), spoken)
        XCTAssertEqual(spoken.components(separatedBy: "Understanding uncertainty").count, 2, "the title is read once")

        let v1Markdown = try PDFStructuredTextExtractor.markdown(from: pdf)
        let v1Title = try XCTUnwrap(v1Markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) })
        let v2Title = try XCTUnwrap(PDFStructuredTextExtractor.itemTitle(for: pdf, structured: document))
        XCTAssertEqual(v2Title, v1Title)

        // The same PDF imported under v1, then again under v2, is one Library item.
        let path = FileManager.default.temporaryDirectory.appending(path: "pdf-692-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]),
            repository: try SQLiteSessionStore(path: path)
        )
        let url = "shared-file://share-sheet/Uncertainty.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Uncertainty"),
            text: v1Markdown,
            contentFormat: .markdown
        ))
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: v2Title),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)
        XCTAssertEqual(reimported.id, v1.id)
    }

    /// A title-only cover, then a page that repeats the title over the authors and the
    /// abstract (#1144: Cambridge CASP working paper "What if automating AI R&D
    /// triggers an intelligence explosion?"; the real PDF is not committed).
    /// `repeatedTitle` is page 2's copy of the title; `abstractInBodyType` sets the "Abstract"
    /// label as the real paper does (12 pt regular, read as body text); `sectionHeading` is a
    /// heading printed over several lines on page 3, after the introduction; `laterProse` is
    /// a sentence on page 3.
    private func coverThenTitlePagePDF(
        coverBody: [String] = [],
        repeatedTitle: [String] = ["What if automating AI R&D triggers an", "intelligence explosion?"],
        abstractInBodyType: Bool = false,
        sectionHeading: [String] = [],
        laterProse: String? = nil
    ) -> Data {
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let coverTitle: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 32)]
        let pageTitle: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 26)]
        let series: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let authors: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let prose = [
            "Listening lets researchers take in papers during time that reading cannot use.",
            "We asked twelve researchers to listen to papers during their daily commute.",
            "Each participant kept a short diary of the sessions over four weeks of study.",
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "What if automating AI R&D triggers an intelligence explosion?"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        return renderer.pdfData { context in
            context.beginPage()
            for (offset, line) in ["What if automating AI R&D", "triggers an intelligence", "explosion?"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 58, y: 300 + CGFloat(offset) * 46), withAttributes: coverTitle)
            }
            ("Frontier AI Working Paper Series No. 2/2026" as NSString).draw(at: CGPoint(x: 58, y: 700), withAttributes: series)
            ("September 2026" as NSString).draw(at: CGPoint(x: 58, y: 724), withAttributes: series)
            for (offset, line) in coverBody.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 58, y: 600 + CGFloat(offset) * 12), withAttributes: body)
            }
            context.beginPage()
            for (offset, line) in repeatedTitle.enumerated() {
                // Centred under the first line when short, as the paper sets it.
                (line as NSString).draw(at: CGPoint(x: offset > 0 && line.count <= 25 ? 160 : 66, y: 64 + CGFloat(offset) * 30),
                                        withAttributes: pageTitle)
            }
            let authorsY = 82 + CGFloat(max(2, repeatedTitle.count)) * 30
            ("Alan Chan" as NSString).draw(at: CGPoint(x: 109, y: authorsY), withAttributes: authors)
            ("Sören Mindermann" as NSString).draw(at: CGPoint(x: 109, y: authorsY + 16), withAttributes: authors)
            ("Abstract" as NSString).draw(at: CGPoint(x: 260, y: 236),
                                          withAttributes: abstractInBodyType ? [.font: UIFont.systemFont(ofSize: 9.5)] : heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 256 + CGFloat(offset) * 12), withAttributes: body)
            }
            context.beginPage()
            ("Introduction" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: heading)
            for (offset, line) in prose.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 110 + CGFloat(offset) * 12), withAttributes: body)
            }
            // Headings set 12 pt with 15 pt leading, like the paper's 14.3 pt with 18 pt.
            for (offset, line) in sectionHeading.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 180 + CGFloat(offset) * 15), withAttributes: heading)
            }
            let after = 190 + CGFloat(sectionHeading.count) * 15
            for (offset, line) in (prose + [laterProse].compactMap { $0 }).enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: after + CGFloat(offset) * 12), withAttributes: body)
            }
        }
    }

    func testV2MakesNoChaptersFromATitleOnlyCoverAndItsRepeatedTitle() throws {
        // #1144 (Build 30): the cover's three title lines and the next page's two lines
        // each became a chapter, because the title-page rule only ran on a first page
        // that held the abstract.
        let pdf = try XCTUnwrap(PDFDocument(data: coverThenTitlePagePDF()))
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let characters = Array(document.text)
        func text(_ segment: StructuredDocument.Segment) -> String {
            String(characters[segment.range.start..<segment.range.end]).split(whereSeparator: \.isNewline).joined(separator: " ")
        }

        XCTAssertEqual(document.segments.filter { $0.role == .heading }.map(text), ["Abstract", "Introduction"])
        XCTAssertEqual(titleSegments(document), ["What if automating AI R&D triggers an intelligence explosion?"],
                       "the cover's three lines are one title, and the repeat is not another")
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertEqual(spoken.components(separatedBy: "intelligence explosion").count, 2, "the title is read once")
        XCTAssertTrue(spoken.contains("Alan Chan"), "author names are read (owner, #191)")
        XCTAssertTrue(spoken.contains("take in papers during time"), "the abstract is still read")
        XCTAssertFalse(spoken.contains("Working Paper Series"))
        XCTAssertEqual(PDFStructuredTextExtractor.itemTitle(for: pdf, structured: document),
                       "What if automating AI R&D triggers an intelligence explosion?")
    }

    func testV2DoesNotTakeAFirstPageWithBodyTextForATitleOnlyCover() throws {
        // A first page that holds prose isn't a cover, so nothing on it is dropped.
        // Long lines, and short ones (under eight words, which the prose test passes over).
        for line in ["A first page that carries sentences of its own, set in ordinary body type for listening.",
                     "Short lines of body type on page one."] {
            let pdf = try XCTUnwrap(PDFDocument(data: coverThenTitlePagePDF(coverBody: [line])))
            let spoken = StructuredDocumentSpeech.spokenLines(try PDFStructuredTextExtractor.structuredDocument(from: pdf)).joined(separator: " ")
            XCTAssertTrue(spoken.contains(String(line.dropLast())), spoken)
        }
    }

    func testV2KeepsBadgesInTheTitleTypeOutOfTheTitle() throws {
        // #692's fix joins short lines above the title only when they sit right above
        // it in the same type, and never an article-type label.
        for (badge, y) in [("sensors", CGFloat(40)), ("Research Article", 70)] {
            let pdf = try XCTUnwrap(PDFDocument(data: titlePagePDF(
                [(badge, y), ("Understanding uncertainty in modern", 90), ("machine learning systems", 110)]
            )))
            let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
            XCTAssertEqual(titleSegments(document), ["Understanding uncertainty in modern machine learning systems"], badge)
        }
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

    func testV2FindsFootnoteMarkersOnAPageSetAboveTheBodySize() throws {
        // #2370: PDFKit read one page of "Technology Bottlenecks" (TeX Gyre Pagella, 10.9 pt)
        // at 11.8 to 12.1 pt. Markers counted only on lines within 0.6 pt of the body size,
        // so that page had none, and its footnote ("1Appendix A gives…") was read aloud.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let larger: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11.2)]
        let marker: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7)]
        let note: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        let cited = NSMutableAttributedString(string: "Bottleneck pressure rises as the rest of the job speeds up.", attributes: larger)
        cited.append(NSAttributedString(string: "1", attributes: marker))
        cited.append(NSAttributedString(string: " Averaged over tasks,", attributes: larger))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            for row in 0..<8 {
                ("Exposure measures ask which work AI can do, line \(row) of the opening page." as NSString)
                    .draw(at: CGPoint(x: 60, y: 80 + CGFloat(row) * 16), withAttributes: body)
            }
            context.beginPage()
            cited.draw(at: CGPoint(x: 60, y: 80))
            ("it ranks occupations differently than exposure does." as NSString).draw(at: CGPoint(x: 60, y: 98), withAttributes: larger)
            ("1 Appendix A gives the conditions under which the measure holds." as NSString).draw(at: CGPoint(x: 60, y: 700), withAttributes: note)
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertFalse(spoken.contains("Appendix A gives the conditions"), spoken)
        XCTAssertTrue(spoken.contains("it ranks occupations differently"), spoken)
    }

    func testV2PutsBackSpacesOnlyInAPdfThatLostThem() throws {
        // #2370: TeX Gyre Pagella has no space glyph, and PDFKit returns its tight lines glued.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        func pdf(_ lines: [String]) -> Data {
            UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
                context.beginPage()
                for (row, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 40, y: 80 + CGFloat(row) * 16), withAttributes: body)
                }
            }
        }
        let glued = pdf([
            "AIexposuremeasureshavebecomethestandardtoolfordescribingwhichoccupations",
            "AIislikelytoaffect(Brynjolfsson,Chandar andChen,2025;Webb,2020),andthey",
            "measurethescopeforAItoperformworkinsteadofwhereitmaypayoffmore.",
            "Ourindexthereforemeasurespressurefromcapabilitybottlenecks,ratherthanintegration",
            "Weaskinsteadwherethemarginalvalueofworkmayriseasthejobspeedsup.",
            "inpostingsthatmentionafeasibletaskandaninfeasibleone,ofallAI-",
            "infeasiblementionsappearinpostingsthatalsolistafeasibletask.",
        ])
        let spaced = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: glued)))
        XCTAssertTrue(spaced.text.contains("the standard tool for describing which occupations"), spaced.text)
        // The broken word's first half is "AI" from the respaced line, not the glued "ofallAI".
        XCTAssertTrue(spaced.text.contains("infeasible mentions appear in postings"), spaced.text)
        // A spaced PDF with a long unlisted word keeps its text exactly.
        let lines = ["Measures of AI exposure have become the standard tool for describing work,",
                     "and Pneumonoultramicroscopicsilicovolcanoconiosis stays as it is printed."]
        let plain = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: pdf(lines))))
        let unspaced = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: pdf(lines))), wordListURL: nil)
        XCTAssertEqual(plain.text, unspaced.text)
    }

    func testV2JudgesAFootnoteLineByItsMainTypeSizeNotItsFirstCharacter() throws {
        // #592 on arXiv 2609.31218 (POPT), sizes from PyMuPDF: body 10 pt, footnote text
        // 8 pt, footnote markers 6 pt, math subscripts 7 pt. A line's size was its first
        // character's, so a body line opening with a 7 pt subscript "m" read as small print
        // and was skipped as a footnote, and a footnote whose 6 pt marker differs from its
        // 8 pt text lost only its first line.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let script: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7)]
        let marker: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 6)]
        let note: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        func line(_ pieces: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
            let line = NSMutableAttributedString()
            for (text, attributes) in pieces { line.append(NSAttributedString(string: text, attributes: attributes)) }
            return line
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("We place one reflecting surface between the base station and the user." as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: body)
            ("Its elements are tuned so that the reflected beam reaches the receiver." as NSString).draw(at: CGPoint(x: 60, y: 96), withAttributes: body)
            context.beginPage()
            line([("The transmitter steers its beam toward the surface in practice,", body), ("1", marker), (" as is usual.", body)])
                .draw(at: CGPoint(x: 60, y: 80))
            ("The received signal is the sum of the direct path and the reflected one." as NSString).draw(at: CGPoint(x: 60, y: 96), withAttributes: body)
            line([("where P is the transmit power and the gain is h", body), ("m", script), (" for each element,", body)])
                .draw(at: CGPoint(x: 60, y: 500))
            line([("m", script), (" (xi) depicts the channel of the surface to the user, while h", body)])
                .draw(at: CGPoint(x: 60, y: 516))
            line([("m", script), (" the single-bounce NLoS component. The total gain follows.", body)])
                .draw(at: CGPoint(x: 60, y: 532))
            line([("1", marker), (" In practice, directional transmit and receive antenna patterns", note)])
                .draw(at: CGPoint(x: 60, y: 690))
            ("are used at both ends of the link in every deployment we measured." as NSString).draw(at: CGPoint(x: 60, y: 700), withAttributes: note)
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        XCTAssertTrue(spoken.contains("depicts the channel of the surface"), spoken)
        XCTAssertTrue(spoken.contains("the single-bounce NLoS component"), spoken)
        XCTAssertFalse(spoken.contains("directional transmit and receive"), spoken)
        XCTAssertFalse(spoken.contains("are used at both ends of the link"), spoken)
        XCTAssertTrue(spoken.contains("as is usual"), spoken)
    }

    func testV2KeepsBodyLinesThatEndInNumbersOffAContentsPage() throws {
        // #354 on arXiv 2608.09666: a page with several lines ending in a number was
        // taken for a table of contents, and "clear: it attains at least 80% Within-1
        // accuracy on 13 of the 15" was skipped as front matter.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16)]
        let numbered = [
            "The advantage is clear: it attains at least 80% accuracy on 13 of the 15",
            "tasks we tested, and it matches the raters on 9 of the 10",
            "settings in the second group, falling short by a margin of 2",
            "points on average across the remaining settings, of which there are 4",
            "in total, each run with three different random seeds.",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("1 Introduction" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: heading)
            ("We asked twelve researchers to listen to papers during their daily commute." as NSString).draw(at: CGPoint(x: 60, y: 110), withAttributes: body)
            context.beginPage()
            for (offset, line) in numbered.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 80 + CGFloat(offset) * 14), withAttributes: body)
            }
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        let spoken = StructuredDocumentSpeech.spokenLines(document).joined(separator: " ")
        for line in numbered {
            XCTAssertTrue(spoken.contains(line), line)
        }
    }

    func testV2KeepsTwoSubsectionsWithTheSameName() throws {
        // #354 on arXiv 2608.09666: "4.1.1 Experimental Setup" (page 5) shares its name
        // with the outline's "4.3.2 Experimental Setup" (page 8), so it counted as a
        // contents entry pointing elsewhere and was skipped.
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let sections = [
            ["4.1.1 Experimental Setup", "4.1.2 Results", "4.1.3 Discussion"],
            ["4.3.1 Experimental Setup", "4.3.2 Results", "4.3.3 Discussion"],
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for headings in sections {
                context.beginPage()
                var y: CGFloat = 80
                for title in headings {
                    (title as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: heading)
                    ("Each participant listened for four weeks and kept a short diary of sessions." as NSString).draw(at: CGPoint(x: 60, y: y + 20), withAttributes: body)
                    y += 60
                }
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = PDFOutline()
        for (pageIndex, headings) in sections.enumerated() {
            let page = try XCTUnwrap(pdf.page(at: pageIndex))
            for title in headings {
                let entry = PDFOutline()
                entry.label = title
                entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
                root.insertChild(entry, at: root.numberOfChildren)
            }
        }
        pdf.outlineRoot = root
        let document = try PDFStructuredTextExtractor.structuredDocument(from: pdf)
        let characters = Array(document.text)
        let headings = document.segments.filter { $0.role == .heading }.map {
            String(characters[$0.range.start..<$0.range.end])
        }
        XCTAssertEqual(headings, sections.flatMap { $0 })
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

    func testV2SideStampTableOfNeighbouringInputs() {
        // #2061: the real stamp of 1706.03762 reached Now as the first sentence.
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let rotated = CGRect(x: 21, y: 182, width: 20, height: 340)
        let upright = CGRect(x: 72, y: 400, width: 468, height: 12)
        let stamps = [
            "arXiv:1706.03762v7 [] 2 Aug 2023",                      // category lost in extraction
            "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023",
            "arXiv:1706.03762v7  [cs.CL]  2  Aug  2023",             // extra spaces
            "arXiv:1706.03762v7\u{00A0}[cs.CL]\u{00A0}2\u{00A0}Aug\u{00A0}2023", // non-breaking spaces
            "arXiv:1706.03762 [cs.CL] 2 Aug 2023",                   // no version
            "arXiv:hep-th/9901001v2 [hep-th] 5 Jan 1999",            // old-style id
            "arXiv:math.GT/0309136v1 [math.GT] 8 Sep 2003",
        ]
        for stamp in stamps {
            XCTAssertTrue(PDFStructuredTextExtractor.isSideStamp(stamp, bounds: rotated, pageBox: box), stamp)
            XCTAssertTrue(PDFStructuredTextExtractor.isSideStamp(stamp, bounds: upright, pageBox: box), "upright: \(stamp)")
            XCTAssertTrue(PDFStructuredTextExtractor.isSideStamp(stamp, bounds: nil, pageBox: box), "no bounds: \(stamp)")
        }
        let body = [
            "We cite arXiv:1706.03762v7 [cs.CL] 2 Aug 2023 in the text.",
            "Attention is all you need. arXiv:1706.03762v7 [cs.CL] 2 Aug 2023",
            "Vaswani et al. arXiv preprint arXiv:1706.03762, 2017.",
            "arXiv:1706.03762v7",
            "2 Aug 2023",
        ]
        for line in body {
            XCTAssertFalse(PDFStructuredTextExtractor.isSideStamp(line, bounds: upright, pageBox: box), line)
            XCTAssertFalse(PDFStructuredTextExtractor.isSideStamp(line, bounds: nil, pageBox: box), "no bounds: \(line)")
        }
    }

    func testV2LeavesTheSideStampOutOfTheDocumentSoItIsNeverTheFirstSentence() throws {
        // #2061: a PDF printed like arXiv 1706.03762: the stamp runs up the left margin,
        // and the body text sits on either side of it in the page's reading order.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Attention is all you need and nothing else." as NSString).draw(at: CGPoint(x: 90, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
            ("The dominant sequence transduction models are based on recurrent networks." as NSString).draw(at: CGPoint(x: 90, y: 160), withAttributes: body)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 36, y: 560)
            context.cgContext.rotate(by: -.pi / 2)
            ("arXiv:1706.03762v7 [cs.CL] 2 Aug 2023" as NSString).draw(at: .zero, withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            context.cgContext.restoreGState()
            ("We propose a new simple network architecture, the Transformer." as NSString).draw(at: CGPoint(x: 90, y: 180), withAttributes: body)
        }
        let document = try PDFStructuredTextExtractor.structuredDocument(from: XCTUnwrap(PDFDocument(data: data)))
        XCTAssertFalse(document.text.contains("arXiv:"), document.text)
        XCTAssertFalse(document.text.contains("2 Aug 2023"), document.text)
        XCTAssertTrue(document.text.contains("Attention is all you need"), document.text)
        XCTAssertFalse(document.segments.contains { $0.role == .pageHeader }, "the stamp is dropped, not labelled")
        XCTAssertTrue(document.text.contains("recurrent networks"))
        XCTAssertTrue(document.text.contains("the Transformer"))
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
