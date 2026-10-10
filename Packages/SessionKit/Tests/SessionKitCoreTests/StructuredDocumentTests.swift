import XCTest
@testable import SessionKit

final class StructuredDocumentTests: XCTestCase {
    private func document(_ lines: [StructuredDocumentLine]) -> StructuredDocument {
        StructuredDocumentBuilder.build(lines: lines, engine: "pdfkit_baseline", version: 2, pageCount: 2)
    }

    func testRangesIndexTheCanonicalTextAndRolesNeverDropIt() throws {
        let doc = document([
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "1 Introduction", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Listening is slower [3], but it fits.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "It fits (Lee, 2019) into commutes.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "[3] C. Writer. Reading. 2020.", role: .reference, pageIndex: 1),
        ])
        let characters = Array(doc.text)
        XCTAssertEqual(doc.segments.map(\.role), [.pageHeader, .heading, .body, .heading, .reference])
        XCTAssertEqual(String(characters[doc.segments[2].range.start..<doc.segments[2].range.end]),
                       "Listening is slower [3], but it fits.\nIt fits (Lee, 2019) into commutes.")
        // Every non-whitespace character is inside some segment (I13 invariant 2).
        var covered = Set<Int>()
        doc.segments.forEach { covered.formUnion($0.range.start..<$0.range.end) }
        XCTAssertTrue(characters.indices.allSatisfy { covered.contains($0) || characters[$0].isWhitespace })
        XCTAssertEqual(doc.markers.map { String(characters[$0.range.start..<$0.range.end]) }, ["[3]", "(Lee, 2019)"])
        XCTAssertEqual(doc.extraction.textSHA256?.count, 64)
    }

    func testAMultiLineTitleIsOneSegmentThatKeepsItsLevelAndMakesNoChapter() throws {
        // #272: a printed title is read once, isn't a chapter, and keeps the level
        // the PDF item title is found by.
        let doc = document([
            StructuredDocumentLine(text: "Listening to Papers: A Field Study", role: .title, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "of Researchers", role: .title, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "Ada Example, Ben Sample", role: .authors, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "1 Introduction", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Listening is slower than reading, but it fits.", role: .body, pageIndex: 0),
        ])
        XCTAssertEqual(doc.segments.map(\.role), [.title, .authors, .heading, .body])
        XCTAssertEqual(doc.segments.map(\.level), [1, nil, 2, nil])
        let chapters = StructuredDocumentImport.listeningMap(for: doc, title: "Listening to Papers", itemId: "item")?.chapters ?? []
        XCTAssertFalse(chapters.contains { $0.title.contains("Field Study") || $0.title.contains("Ada Example") })
    }

    func testTitleIdentitySurvivesRoundTripAlongsideFootnotes() throws {
        // #272 and #250 touch the same extractor path. Keeping the title's old
        // heading level must not create title-page chapters or read footnotes.
        let original = document([
            StructuredDocumentLine(text: "Listening to Papers: A Field Study", role: .title, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "of Researchers", role: .title, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "Ada Example, Ben Sample", role: .authors, pageIndex: 0),
            StructuredDocumentLine(text: "v1", role: .frontMatter, pageIndex: 0),
            StructuredDocumentLine(text: "1 Introduction", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Participants kept diaries.", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "1 Diaries were transcribed later.", role: .footnote, pageIndex: 1),
        ])
        let doc = try JSONDecoder().decode(StructuredDocument.self, from: JSONEncoder().encode(original))
        let title = try XCTUnwrap(doc.segments.first { $0.role == .title })
        XCTAssertEqual(title.level, 1, "the v1 level used to find the item title survives persistence")
        let characters = Array(doc.text)
        let titleText = String(characters[title.range.start..<title.range.end])
        XCTAssertEqual(titleText.split(whereSeparator: \.isNewline).first.map(String.init),
                       "Listening to Papers: A Field Study")
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: doc, title: "Listening to Papers", itemId: "item"))
        // The canonical map includes one front-matter span before the first
        // section, rather than a chapter for each title or author line.
        XCTAssertEqual(map.chapters.map(\.title), ["Front Matter", "1 Introduction"])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "Listening to Papers: A Field Study",
            "of Researchers",
            "Ada Example, Ben Sample",
            "1 Introduction",
            "Participants kept diaries.",
        ])
    }

    func testSpeechFollowsI14AndMapsBackToTheCanonicalText() throws {
        let doc = document([
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose [12, 14] as shown (Smith et al., 2020).", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Participant Sessions P1 14", role: .table, pageIndex: 0),
            StructuredDocumentLine(text: "[1] A. Author. Title. 2019.", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "Journal of Examples 2", role: .pageFooter, pageIndex: 1),
            StructuredDocumentLine(text: "[2] B. Author. Title. 2020.", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "Appendix A", role: .heading, pageIndex: 1, level: 2),
        ])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "Methods",
            "Levels rose as shown.",
            "Table not read.",
            // One notice for the whole list, even across a page footer.
            "References skipped.",
            "Appendix A",
        ])
        let listenable = StructuredDocumentSpeech.listenableText(doc)
        let characters = Array(doc.text)
        let spoken = Array(listenable.text)
        // Every spoken character that isn't an announcement is the same character in the text.
        let appendix = try XCTUnwrap(listenable.text.range(of: "Appendix A"))
        let offset = listenable.text.distance(from: listenable.text.startIndex, to: appendix.lowerBound)
        XCTAssertEqual(String(characters[listenable.sourceOffset(atSpokenCharacterOffset: offset)...].prefix(10)), "Appendix A")
        let tableNotice = listenable.text.distance(from: listenable.text.startIndex, to: try XCTUnwrap(listenable.text.range(of: "Table not read.")).lowerBound)
        XCTAssertEqual(listenable.sourceOffset(atSpokenCharacterOffset: tableNotice), doc.segments.first { $0.role == .table }?.range.start)
        XCTAssertEqual(spoken.count, listenable.sourceOffsets.count)
    }

    func testAWordHyphenatedAtALineEndIsSpokenWhole() throws {
        // #220 T4: "agree-\nment" was spoken "agree, ment" on two-column papers.
        let doc = document([
            StructuredDocumentLine(text: "Adjustable agree-", role: .body, pageIndex: 0, endsWithSoftHyphen: true),
            StructuredDocumentLine(text: "ment thresholds (see Sec-", role: .body, pageIndex: 0, endsWithSoftHyphen: true),
            StructuredDocumentLine(text: "tion 8) and Mixtral-", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "8x7B were used with chain-of-", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "thought prompts.", role: .body, pageIndex: 0),
        ])
        // A compound broken at its hyphen keeps it; the extractor marks only real splits.
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "Adjustable agreement thresholds (see Section 8) and Mixtral-8x7B were used with chain-of-thought prompts.",
        ])
        // The joined word still maps into the canonical text, so positions don't move.
        let listenable = StructuredDocumentSpeech.listenableText(doc)
        let spokenStart = listenable.text.distance(from: listenable.text.startIndex, to: try XCTUnwrap(listenable.text.range(of: "agreement")).lowerBound)
        XCTAssertEqual(listenable.sourceOffset(atSpokenCharacterOffset: spokenStart), doc.text.distance(from: doc.text.startIndex, to: doc.text.range(of: "agree-")!.lowerBound))
    }

    func testAReferenceListInterruptedOnlyByHeadingsIsAnnouncedOnce() {
        // #220 T4 on 96cbef0: PDFKit read the Appendix headings between the two columns of
        // a reference page, and "References skipped." played again after them.
        let doc = document([
            StructuredDocumentLine(text: "The paper ends here.", role: .body, pageIndex: 9),
            StructuredDocumentLine(text: "References", role: .reference, pageIndex: 9),
            StructuredDocumentLine(text: "Tianyi Zhang, et al. 2020. BERTScore.", role: .reference, pageIndex: 9),
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 10, level: 1),
            StructuredDocumentLine(text: "Large Language Models Used", role: .heading, pageIndex: 10, level: 2),
            StructuredDocumentLine(text: "Max Schäfer, et al. 2024. Unit tests.", role: .reference, pageIndex: 10),
            StructuredDocumentLine(text: "The following LLMs were used.", role: .body, pageIndex: 10),
            StructuredDocumentLine(text: "Supplementary references", role: .heading, pageIndex: 11, level: 1),
            StructuredDocumentLine(text: "[S1] A. Writer. 2021.", role: .reference, pageIndex: 11),
        ])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "The paper ends here.",
            "References skipped.",
            "Appendix",
            "Large Language Models Used",
            "The following LLMs were used.",
            "Supplementary references",
            // A separate list after body text is announced again: nothing disappears unannounced.
            "References skipped.",
        ])
    }

    func testATableSplitByAPageBreakIsAnnouncedOnce() {
        let doc = document([
            StructuredDocumentLine(text: "Before.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "P1 14 9", role: .table, pageIndex: 0),
            StructuredDocumentLine(text: "Journal 3", role: .pageFooter, pageIndex: 0),
            StructuredDocumentLine(text: "P2 9 4", role: .table, pageIndex: 1),
            StructuredDocumentLine(text: "Between.", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "P3 1 2", role: .table, pageIndex: 1),
        ])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), ["Before.", "Table not read.", "Between.", "Table not read."])
    }

    func testTextInsideAFigureIsSilentAndItsCaptionIsRead() {
        let doc = document([
            StructuredDocumentLine(text: "Figure 2. Sessions by hour.", role: .caption),
            StructuredDocumentLine(text: "0 6 12 18 24", role: .figureText),
            StructuredDocumentLine(text: "Most sessions were early.", role: .body),
        ])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), ["Figure 2. Sessions by hour.", "Most sessions were early."])
    }

    func testSuperscriptMarkersFollowCleaningAndAreSilent() throws {
        let doc = document([
            StructuredDocumentLine(text: "Vitamin  D matters12 and so do diets.a", role: .body, pageIndex: 0, superscripts: [18..<20, 37..<38]),
        ])
        let characters = Array(doc.text)
        XCTAssertEqual(doc.text, "Vitamin D matters12 and so do diets.a")
        XCTAssertEqual(doc.markers.map(\.kind), [.citation, .footnote])
        XCTAssertEqual(doc.markers.map { String(characters[$0.range.start..<$0.range.end]) }, ["12", "a"])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), ["Vitamin D matters and so do diets."])
    }

    func testNarrativeCitationNamesStayInTheSentence() {
        let doc = document([
            StructuredDocumentLine(text: "Pittas et al. (2019) reported it, as did Lee and Park (2020).", role: .body),
        ])
        XCTAssertTrue(doc.markers.isEmpty)
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc).first?.hasPrefix("Pittas et al."), true)
    }

    private func citationLabels(_ body: [String], references: [String]?) -> [String] {
        var lines = body.map { StructuredDocumentLine(text: $0, role: .body, pageIndex: 0) }
        if let references {
            lines.append(StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2))
            lines += references.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) }
        }
        let doc = document(lines)
        let characters = Array(doc.text)
        return doc.markers.map { String(characters[$0.range.start..<$0.range.end]) }
    }

    private let numberedReferences = (1...20).map { "\($0). Author \($0). Title. Journal. 2019." }

    func testRoundBracketNumbersAreCitationsWhenTheReferenceListIsNumbered() {
        // #138: "(17)" and "(3–5, 8)" were read aloud; [17] already was silent.
        let body = ["Cells divide (17).", "This was shown before (3–5, 8).", "A range may use a hyphen (3-5) or spaces (3 – 5 , 8)."]
        XCTAssertEqual(citationLabels(body, references: numberedReferences),
                       ["(17)", "(3–5, 8)", "(3-5)", "(3 – 5, 8)"])
        XCTAssertEqual(citationLabels(["Cells divide [17]."], references: ["[1] Ada.", "[2] Ben.", "[3] Dee."]), ["[17]"])
        XCTAssertEqual(citationLabels(["Cells divide (3) here, and then (1)."], references: ["[1] Ada.", "[2] Ben.", "[3] Cy."]), ["(3)", "(1)"],
                       "a lone (1) or (3) after a word is a citation; only neighbouring digits list things")
        let doc = document([
            StructuredDocumentLine(text: "Cells divide (17).", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        ] + numberedReferences.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) })
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc).first, "Cells divide.")
    }

    func testOrdinaryNumbersInParenthesesAreStillRead() {
        let listed = numberedReferences
        XCTAssertEqual(citationLabels(["We tested (1) speed and (2) accuracy."], references: listed), [])
        XCTAssertEqual(citationLabels(["The effect was large, n = 12 (95% CI)."], references: listed), [])
        XCTAssertEqual(citationLabels(["Cells divide (17)."], references: nil), [], "no reference list")
        XCTAssertEqual(citationLabels(["In 2019 (2) groups met."], references: nil), [])
        XCTAssertEqual(citationLabels(["Cells divide (17)."], references: ["Ada A. Cells. J Biol. 2019.", "Ben B. Growth. 2020.", "Cy C. Mitosis. 2018."]),
                       [], "author-year references are not numbered")
        XCTAssertEqual(citationLabels(["Cells divide (40)."], references: listed), [], "no such entry")
        XCTAssertEqual(citationLabels(["Substituting into Eq. (2), we get x. Also see Figure (3) and Table (4)."], references: listed), [])
        XCTAssertEqual(citationLabels(["Responses used a Likert scale (1–5); ages (10–15) were included. E = mc² (3)"], references: listed), [])
        XCTAssertEqual(citationLabels(["Aims were (1), (2) and (3) as follows.", "(2) Second item", "We counted (1) 5 patients."], references: listed), [])
        let wrapped = ["1. Ada A. Cells. J Biol.", "45 (2):100–5.", "2. Ben B. Growth.", "10 mg doses were given.", "3. Cy C. Mitosis."]
        XCTAssertEqual(citationLabels(["Cells divide (17)."], references: wrapped), [], "wrapped lines do not make a 45-entry list")
        XCTAssertEqual(citationLabels(["(17) is the question."], references: listed), [], "nothing before it to cite")
        XCTAssertEqual(citationLabels(["The year (2020) began."], references: listed), [])
        XCTAssertEqual(citationLabels(["Cells divide (2)."], references: Array(numberedReferences.prefix(2))), [], "two entries are not a list")
        XCTAssertEqual(citationLabels(["Cells divide (4)."], references: Array(numberedReferences.suffix(10))), [], "a list that does not start at 1")
    }

    func testDocumentRoundTripsAsI13JSON() throws {
        let doc = document([StructuredDocumentLine(text: "Body [1].", role: .body, pageIndex: 0)])
        let json = try JSONEncoder().encode(doc)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "structured-document.v1")
        XCTAssertEqual((object["segments"] as? [[String: Any]])?.first?["role"] as? String, "body")
        XCTAssertEqual(try JSONDecoder().decode(StructuredDocument.self, from: json), doc)
    }

    func testAnOutlineChapterWithNoPrintedHeadingIsAnchoredAndNeverSpoken() throws {
        // #355: an outline title with no matching line was inserted at the top of its page
        // and read aloud, and the run-in heading that really starts the section read again.
        let doc = document([
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "We asked twelve researchers.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "   ", role: .body, pageIndex: 1, outlineEntries: [.init(title: "Light stimulation", level: 2)]),
            StructuredDocumentLine(text: "Light stimulation: flashes were full-field.", role: .body, pageIndex: 1),
        ])
        let characters = Array(doc.text)
        let anchor = try XCTUnwrap(doc.outline?.first)
        XCTAssertEqual(anchor.title, "Light stimulation")
        XCTAssertEqual(String(characters[anchor.start...].prefix(18)), "Light stimulation:", "moved past the empty line")
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "Methods", "We asked twelve researchers.", "Light stimulation: flashes were full-field.",
        ], "the title is spoken once, where it's printed")
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: doc, title: "Paper", itemId: "item"))
        XCTAssertEqual(map.chapters.map(\.title), ["Methods", "Light stimulation"])
        XCTAssertEqual(map.chapters.last?.startChar, anchor.start)
    }

    func testOutlineAnchorsAreOptionalInStoredDocuments() throws {
        // Documents saved before anchors existed decode, and one with none doesn't write the key.
        let plain = document([StructuredDocumentLine(text: "Body.", role: .body, pageIndex: 0)])
        XCTAssertNil(plain.outline)
        let encoded = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("outline"))
        XCTAssertEqual(try JSONDecoder().decode(StructuredDocument.self, from: encoded), plain)

        let anchored = document([StructuredDocumentLine(text: "Body.", role: .body, pageIndex: 0, outlineEntries: [.init(title: "A", level: 1)])])
        let roundTrip = try JSONDecoder().decode(StructuredDocument.self, from: JSONEncoder().encode(anchored))
        XCTAssertEqual(roundTrip.outline, [StructuredDocument.OutlineAnchor(title: "A", level: 1, start: 0)])
    }
}
