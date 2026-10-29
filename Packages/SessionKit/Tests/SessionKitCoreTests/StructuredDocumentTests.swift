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
        // No chapter for each title or author line, and none for the title page as a
        // whole: it is the start of the first chapter (#1144).
        XCTAssertEqual(map.chapters.map(\.title), ["1 Introduction"])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
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

    func testAuthorYearCitationsWithThreeOrMoreAuthorsAndYearListsAreCitations() {
        // #2370: natbib/AER style from "Technology Bottlenecks" (Shukla, 2026); only the
        // two-author "(Becker and Murphy, 1992)" matched before.
        let sentences = [
            "describing which occupations AI is likely to affect (Brynjolfsson, Chandar and Chen, 2025; Webb, 2020), and",
            "a potential “mini Baumol” effect (Aghion, Jones and Jones, 2019; Baumol, 1967), suggesting that",
            "the labor that performs them (Agrawal, Gans and Goldfarb, 2019, 2024; Autor, 2024; Imas and Shukla, 2026a).",
            "task-based models (Acemoglu and Autor, 2011; Autor, Levy and Murnane, 2003) treat",
            // The same citation from a PDF that lost its spaces, after the spacer (#2370).
            "likely to affect (Brynjolfsson, Chandar and Chen,2025; Webb,2020)",
            "as in (Becker and Murphy, 1992).",
        ]
        XCTAssertEqual(citationLabels(sentences, references: nil), [
            "(Brynjolfsson, Chandar and Chen, 2025; Webb, 2020)",
            "(Aghion, Jones and Jones, 2019; Baumol, 1967)",
            "(Agrawal, Gans and Goldfarb, 2019, 2024; Autor, 2024; Imas and Shukla, 2026a)",
            "(Acemoglu and Autor, 2011; Autor, Levy and Murnane, 2003)",
            "(Brynjolfsson, Chandar and Chen,2025; Webb,2020)",
            "(Becker and Murphy, 1992)",
        ])
        XCTAssertEqual(citationLabels(["GPT-4 ratings from Eloundou et al. (2024) construct a measure."], references: nil), [])
        XCTAssertEqual(citationLabels(["We tested (1) speed and (2) accuracy."], references: numberedReferences), [])
        // An author-year paper like this one has no numbered list; with one, "(2)" is a citation (#138).
        XCTAssertEqual(citationLabels(["In 2019 (2) groups met."], references: nil), [])
        XCTAssertEqual(citationLabels(["Sales rose (Table 2, 2019) and fell (in 2020)."], references: nil), [])
        XCTAssertEqual(citationLabels(["The summit (Paris, France, 2019) met."], references: nil), [])
        XCTAssertEqual(citationLabels(["As shown (Smith, Jones, & Lee, 2019)."], references: nil), ["(Smith, Jones, & Lee, 2019)"])
        XCTAssertEqual(citationLabels(["As shown (Smith &Jones, 2019)."], references: nil), ["(Smith &Jones, 2019)"])
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

    func testSuperscriptCitationsFlattenedOntoPunctuationAreCitations() {
        // #138: the extractor missed these superscripts, so "concept.13 This" read "thirteen".
        let body = [
            "Exclusion is a relative concept.13 This means a lot.",
            "Integration covers values and norms).14 15 Social exclusion grew.",
            "Protection held for Alpha but not Beta,4–6 likely due to escape.",
            "This holds in the retina,3,4 where stimuli vary.",
            "Goleman (1998)6 presents five components.",
            "It escaped Alpha and Beta (B.1.351)3; vaccines still worked.",
            "And it ends the paragraph.17",
        ]
        XCTAssertEqual(citationLabels(body, references: numberedReferences), ["13", "14 15", "4–6", "3,4", "6", "3", "17"])
        let doc = document([
            StructuredDocumentLine(text: "Exclusion is a relative concept.13 This means a lot.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        ] + numberedReferences.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) })
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc).first, "Exclusion is a relative concept. This means a lot.")
        // The number column read as one line, before the first entry's text.
        let stacked = ["1. 2. 3. 4. 5. 6. 7. 8. Woodworth RS: Psychology. 1940.", "Lewis M: Self-conscious emotions. 2008.", "9. 10. Cherniss C. 2001."]
        XCTAssertEqual(citationLabels(["It was revived,9 he said."], references: stacked), ["9"])
        XCTAssertEqual(citationLabels(["It was revived,9 he said."], references: ["1. 2 mg doses. 2019.", "Lewis M. 2008.", "Cherniss C. 2001."]), [],
                       "a number after a space is the entry's text, not the next entry")
    }

    func testNumbersAfterPunctuationThatAreProseAreStillRead() {
        let listed = numberedReferences
        XCTAssertEqual(citationLabels(["Exclusion is a relative concept.13 This means a lot."], references: nil), [], "no reference list")
        XCTAssertEqual(citationLabels(["Exclusion is a relative concept.45 This means a lot."], references: listed), [], "no such entry")
        XCTAssertEqual(citationLabels(["The dose was 0.18 mg, and 3,4 more.", "COVID-19.2 cases rose."], references: listed), [])
        XCTAssertEqual(citationLabels(["Strain B.1 was common, see Fig.2 and No.5 and ref.3 here."], references: listed), [])
        XCTAssertEqual(citationLabels(["We used MSigDB v7.3 today.", "The ratio was 3:1 then."], references: listed), [])
        XCTAssertEqual(citationLabels(["Then x = (a+b)2 holds, and (n)2 too, and (a, b)2 and (x,y)2."], references: listed), [],
                       "a square, not a citation")
        XCTAssertEqual(citationLabels(["Patients left the cohort.3 12 patients stayed."], references: listed), [],
                       "after a full stop, a number followed by more numbers is not the end of a sentence")
        XCTAssertEqual(citationLabels(["It took a dose,3 12 more."], references: listed), ["3"],
                       "a second number after a space joins the citation only when a new sentence follows")
        XCTAssertEqual(citationLabels(["Doses were given at noon.5mg each."], references: listed), [], "the number runs into a word")
        XCTAssertEqual(citationLabels(["Omicron BA.1 variants, and Omicron BA.1 (p < 0.01).", "We used DSH 0.1.5-rc.2, both times.",
                                       "Most were class I or II.1 without pain.", "The Sah:1 equation."], references: listed), [],
                       "after a full stop a citation ends the sentence")
        XCTAssertEqual(citationLabels(["Lead nitrate Pb(NO3)2 was used, and f(x)2 is smooth; log(|R|)3 too."], references: listed), [],
                       "a bracket stuck to a word is a formula")
        XCTAssertEqual(citationLabels(["See Tab.2 Here, Thm.3 There and Eqn.4 Now."], references: listed), [])
        XCTAssertEqual(citationLabels(["Of these,15 were male.", "The PDF lost spaces,as here,and here,and there."], references: listed), [],
                       "a document that drops the space after commas")
        XCTAssertEqual(citationLabels(["Translocations t(18) and dup(10) and inv(22) were seen."], references: listed), [],
                       "a bracket stuck to a short word is notation")
        XCTAssertEqual(citationLabels(["We used the mapper(17),atool.", "It self-cleaves(3,4),as shown."], references: listed), ["(17)", "(3,4)"],
                       "a PDF that lost its spaces still cites")
        XCTAssertEqual(citationLabels(["Cells divide [3], [4] and [5].", "It held.6 Then it fell.7 Later.8 Again.9 More."], references: listed),
                       ["[3]", "[4]", "[5]", "6", "7", "8", "9"], "mostly flattened superscripts, with a few square brackets")
        XCTAssertEqual(citationLabels(["Cells divide [3].", "As in [4] and [5], [6], [7] and [8].", "By Eqs (2)–(4) and (8) and (9), it holds.", "It held.6 Then it fell."],
                                      references: listed), ["[3]", "[4]", "[5]", "[6]", "[7]", "[8]"],
                       "a paper that cites in square brackets numbers its equations in round ones")
    }

    /// A body line whose `marker` is printed as a superscript.
    private func superscripted(_ text: String, _ marker: String) -> StructuredDocumentLine {
        let characters = Array(text)
        let start = text.range(of: marker).map { characters.count - text[$0.lowerBound...].count } ?? 0
        return StructuredDocumentLine(text: text, role: .body, pageIndex: 0, superscripts: [start..<(start + marker.count)])
    }

    private func labels(_ doc: StructuredDocument) -> [String] {
        let characters = Array(doc.text)
        return doc.markers.map { String(characters[$0.range.start..<$0.range.end]) }
    }

    func testSuperscriptRunCutByTheLineEndIsOneCitation() {
        // #1189, pmc-pmc7619013: "prey capture,19,34–" ends a line and "38" opens the next one,
        // so "38" was read aloud: "thirty-eight and two the peripheral".
        let doc = document([
            superscripted("surveys upper frontal visual space, including prey capture,19,34–", "19,34–"),
            StructuredDocumentLine(text: "38 and (2) the peripheral nasal retina, which surveys the horizon.", role: .body, pageIndex: 0),
            superscripted("circuits?12–", "12–"),
            StructuredDocumentLine(text: "14 All of the processing channels involve amacrine cells.", role: .body, pageIndex: 0),
        ])
        XCTAssertEqual(labels(doc), ["19,34–", "38", "12–", "14"])
        XCTAssertEqual(StructuredDocumentSpeech.spokenLines(doc), [
            "surveys upper frontal visual space, including prey capture,",
            "and (2) the peripheral nasal retina, which surveys the horizon.",
            "circuits?",
            "All of the processing channels involve amacrine cells.",
        ])
    }

    func testNumbersThatOpenALineAreReadUnlessASuperscriptRunWasCutThere() {
        func opening(after first: StructuredDocumentLine, _ second: String, role: StructuredDocument.Role = .body) -> [String] {
            labels(document([first, StructuredDocumentLine(text: second, role: role, pageIndex: 0)]))
        }
        let open = superscripted("capture,19,34–", "19,34–")
        XCTAssertEqual(opening(after: open, "38"), ["19,34–", "38"], "the whole line is the end of the run")
        XCTAssertEqual(opening(after: open, "38–40 and later"), ["19,34–", "38–40"])
        // The previous run is finished, or is not a citation's.
        XCTAssertEqual(opening(after: superscripted("capture,19,34 and more", "19,34"), "38 patients stayed."), ["19,34"])
        XCTAssertEqual(opening(after: superscripted("capture,19,34 and", "19,34"), "38 patients stayed."), ["19,34"])
        XCTAssertEqual(opening(after: StructuredDocumentLine(text: "From 2019 to 2024–", role: .body, pageIndex: 0), "38 patients stayed."), [])
        // A year, a list number, a decimal or a word is not a continuation.
        XCTAssertEqual(opening(after: open, "2020 was the year."), ["19,34–"])
        XCTAssertEqual(opening(after: open, "14. Next, we tested."), ["19,34–"])
        XCTAssertEqual(opening(after: open, "3.5 mg was given."), ["19,34–"])
        XCTAssertEqual(opening(after: open, "Then we tested."), ["19,34–"])
        XCTAssertEqual(opening(after: open, "38 mg doses.", role: .reference), ["19,34–"], "only body lines continue")
        // A comma after the number ends the run; a run cut again goes on to the third line.
        XCTAssertEqual(opening(after: open, "38, and 40 followed."), ["19,34–", "38,"])
        XCTAssertEqual(labels(document([open,
                                        StructuredDocumentLine(text: "38,40–", role: .body, pageIndex: 0),
                                        StructuredDocumentLine(text: "42 and so on.", role: .body, pageIndex: 0)])),
                       ["19,34–", "38,40–", "42"])
        // Not entries of a numbered reference list, or a thousands figure.
        func withReferences(_ second: String) -> [String] {
            labels(document([open, StructuredDocumentLine(text: second, role: .body, pageIndex: 0),
                             StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2)]
                            + numberedReferences.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) }))
        }
        XCTAssertEqual(withReferences("18 and 19 were used."), ["19,34–", "18"])
        XCTAssertEqual(withReferences("50 patients were enrolled."), ["19,34–"])
        XCTAssertEqual(withReferences("12,000 patients were enrolled."), ["19,34–"])
        XCTAssertEqual(opening(after: open, "12,000 patients were enrolled."), ["19,34–"])
    }

    func testSuperscriptCitationsSetApartAfterAFullStopAreCitationsInASuperscriptPaper() {
        // #1189, pmc-pmc7619013: "respectively. 18,19 Of these" had a space before the superscript.
        let superscripts = (1...5).map { superscripted("Cells divide here\($0) and then stop.", "\($0)") }
        let numbered = (1...20).map { StructuredDocumentLine(text: "\($0). Author \($0). Title. 2019.", role: .reference, pageIndex: 1) }
        func spaced(_ line: String, with context: [StructuredDocumentLine] = superscripts) -> [String] {
            labels(document(context + [StructuredDocumentLine(text: line, role: .body, pageIndex: 0)] + numbered)).dropFirst(context.count).map { $0 }
        }
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 18,19 Of these, long wavelength opponency is encoded."), ["18,19"])
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 7 Of these, long wavelength opponency is encoded."), ["7"])
        // Prose keeps its numbers: no superscripts elsewhere, no such entry, a decimal, a lowercase word.
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 18,19 Of these, some were.", with: []), [])
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 45 Of these, some were."), [])
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 7 of these were."), [])
        XCTAssertEqual(spaced("Samples were taken in Table 2. 7 Of these were kept."), [])
        XCTAssertEqual(spaced("Counts rose; see Fig. 7 Of these, none were."), [])
        XCTAssertEqual(spaced("The cones were green and blue, respectively. 19,18 Of these, some were."), [], "out of order")
        XCTAssertEqual(spaced("As noted by Smith et al. 12 Of the samples failed."), [])
        XCTAssertEqual(spaced("Cells were counted at 10 min. 12 Of these died."), [])
        XCTAssertEqual(spaced("These are shown in Supp. 5 Of the data."), [])
    }

    func testASuperscriptThatOpensTheLineAfterAFullStopIsACitationInASuperscriptPaper() {
        // #1189, pmc-pmc7619014 and pmc-pmc13305550: the superscript after "IFN-γ." wrapped to the
        // next line, "46 In the CD16+ NK cells", and was read "forty-six".
        let superscripts = (1...5).map { superscripted("Cells divide here\($0) and then stop.", "\($0)") }
        let numbered = (1...50).map { StructuredDocumentLine(text: "\($0). Author \($0). Title. 2019.", role: .reference, pageIndex: 1) }
        func opening(_ first: String, _ rest: String..., with context: [StructuredDocumentLine] = superscripts) -> [String] {
            let lines = ([first] + rest).map { StructuredDocumentLine(text: $0, role: .body, pageIndex: 0) }
            return labels(document(context + lines + numbered)).dropFirst(context.count).map { $0 }
        }
        XCTAssertEqual(opening("cytokines such as IFN-γ.", "46 In the CD16+ NK cells, expression rose."), ["46"])
        XCTAssertEqual(opening("in one or another direction”", ".", "12 He published his findings."), ["12"])
        XCTAssertEqual(opening("as reported before.", "14,15 Essential definitions of the term followed."), ["14,15"])
        XCTAssertEqual(opening("infection with Clostridioides difficile.", "2 Recent studies have"), ["2"], "a short line of a sentence")
        // Prose keeps its numbers: no superscripts elsewhere, no such entry, a lowercase word, a number before the stop.
        XCTAssertEqual(opening("cytokines such as IFN-γ.", "46 In the CD16+ NK cells, expression rose.", with: []), [])
        XCTAssertEqual(opening("cytokines such as IFN-γ.", "60 In the CD16+ NK cells, expression rose."), [])
        XCTAssertEqual(opening("cytokines such as IFN-γ.", "46 patients were enrolled."), [])
        XCTAssertEqual(opening("Samples are in Table 2.", "7 Of these were kept."), [])
        XCTAssertEqual(opening("Counts rose; see Fig.", "7 Of these, none were."), [])
        XCTAssertEqual(opening("cytokines such as IFN-γ", "46 In the CD16+ NK cells, expression rose."), [], "no full stop before the line break")
        // A heading stub or a numbered list that opens the line keeps its number.
        XCTAssertEqual(opening("Ten were excluded.", "2 Materials and Methods"), [])
        XCTAssertEqual(opening("Ten were excluded.", "2 Results"), [])
        XCTAssertEqual(opening("The steps were as follows.", "1 Mix the reagents in a tube.", "2 Heat the tube to 90 C."), [])
        XCTAssertEqual(opening("Then heat it.", "3 Cool the tube on ice for a while.", "4 Spin the tube down."), [])
    }

    func testASuperscriptStuckToEtAlIsACitation() {
        // #1189, pmc-pmc10756882: "Cao et al.22 considered a block" read "twenty-two".
        XCTAssertEqual(citationLabels(["To exploit adjacent pixels, Cao et al.22 considered a block."], references: numberedReferences + (21...30).map { "\($0). Author \($0). Title. 2019." }), ["22"])
        XCTAssertEqual(citationLabels(["Cao et al.3,4 considered a block."], references: numberedReferences), ["3,4"])
        // A spaced number after "et al." stays read, and so does a number no entry has.
        XCTAssertEqual(citationLabels(["As noted by Cao et al. 12 of the samples failed."], references: numberedReferences), [])
        XCTAssertEqual(citationLabels(["Cao et al.45 considered a block."], references: numberedReferences), [])
        XCTAssertEqual(citationLabels(["The Bet al.3 considered a block."], references: numberedReferences), [], "only after the words et al.")
    }

    func testNeighbouringSuperscriptNumbersBeforeALowercaseWordAreOneCitation() {
        // #1189, pmc-pmc11150781: "motor function,35 36" then "although" on the next line.
        let listed = numberedReferences
        XCTAssertEqual(citationLabels(["Worsening of neuropsychiatric symptoms and motor function,35 36", "although these effects are not restricted."],
                                      references: listed.prefix(40) + (21...40).map { "\($0). Author \($0). Title. 2019." }), ["35 36"])
        XCTAssertEqual(citationLabels(["It took a dose,3 12 more."], references: listed), ["3"], "numbers that are not neighbours are not both entries")
        XCTAssertEqual(citationLabels(["It took a dose,3 5 more."], references: listed), ["3"])
        XCTAssertEqual(citationLabels(["It took a dose,4 3 more."], references: listed), ["4"])
        XCTAssertEqual(citationLabels(["It took a dose,3 4 mg daily.", "Mice received the drug,2 3 days before surgery."], references: listed), ["3", "2"],
                       "neighbouring numbers join only across a line break")
    }

    func testSquareBracketCitationsWithALocatorAreCitations() {
        // #138: "[7, Lemma A.1]" read "seven, Lemma A one" in maths papers.
        let body = [
            "The minimiser is unique (see [7, Lemma A.1]). Moreover it is even.",
            "Existence is guaranteed by [1, Theorem 2.1]. Next we show it.",
            "Sparser models keep their accuracy [48, p. 214].",
            "The following properties hold (see [2, Lemma 3 and Theorem 7]).",
        ]
        XCTAssertEqual(citationLabels(body, references: nil),
                       ["[7, Lemma A.1]", "[1, Theorem 2.1]", "[48, p. 214]", "[2, Lemma 3 and Theorem 7]"])
        XCTAssertEqual(citationLabels(["Pick a point in [1, x] or [2, the end]."], references: nil), [], "no locator word")
        XCTAssertEqual(citationLabels(["Take [1, part of the set] and [0, section] here."], references: nil), [],
                       "a locator word with no number or label after it is an interval")
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

    // MARK: The title page before the first chapter (#1144)

    private func sections(_ titles: [String], level: Int = 3, page: Int = 2) -> [StructuredDocumentLine] {
        titles.flatMap { title in [
            StructuredDocumentLine(text: title, role: .heading, pageIndex: page, level: level),
            StructuredDocumentLine(text: "This section of the paper has ordinary prose about \(title).", role: .body, pageIndex: page),
        ] }
    }

    private let titlePage: [StructuredDocumentLine] = [
        StructuredDocumentLine(text: "What if automating AI R&D", role: .title, pageIndex: 0, level: 1),
        StructuredDocumentLine(text: "triggers an intelligence", role: .title, pageIndex: 0, level: 1),
        StructuredDocumentLine(text: "explosion?", role: .title, pageIndex: 0, level: 1),
        StructuredDocumentLine(text: "Frontier AI Working Paper Series No. 2/2026", role: .frontMatter, pageIndex: 0),
        StructuredDocumentLine(text: "September 2026", role: .frontMatter, pageIndex: 0),
        StructuredDocumentLine(text: "What if automating AI R&D triggers an", role: .frontMatter, pageIndex: 1),
        StructuredDocumentLine(text: "intelligence explosion?", role: .frontMatter, pageIndex: 1),
        StructuredDocumentLine(text: "Alan Chan* GovAI", role: .authors, pageIndex: 1),
        StructuredDocumentLine(text: "Christoph Winter CASP, University of Cambridge", role: .frontMatter, pageIndex: 1),
        StructuredDocumentLine(text: "Jack Clark Anthropic", role: .authors, pageIndex: 1),
    ]

    private let paperTitle = "What if automating AI R&D triggers an intelligence explosion?"
    private let paperSections = ["Introduction", "AI is rapidly automating AI R&D",
                                 "Automating AI R&D could trigger an intelligence explosion", "Societal impacts", "Conclusion"]

    private func abstract(_ label: String, role: StructuredDocument.Role = .body) -> [StructuredDocumentLine] {
        [
            StructuredDocumentLine(text: label, role: role, pageIndex: 1, level: role == .heading ? 3 : nil),
            StructuredDocumentLine(text: "In contrast to even a year ago, AI systems now write most of the code inside the companies", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "that build them.", role: .body, pageIndex: 1),
        ]
    }

    func testTheRealPapersTitlePageIsPartOfAnAbstractChapter() throws {
        // The Test Desk's chapter list on next 6a22bb8 began "Front Matter", which held the
        // title, the series line, the repeated title, the authors and the abstract.
        let doc = document(titlePage + abstract("Abstract") + sections(paperSections))
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: doc, title: paperTitle, itemId: "item"))
        XCTAssertEqual(map.chapters.map(\.title), ["Abstract"] + paperSections)
        XCTAssertEqual(map.chapters.first?.startChar, 0, "the title page is heard at the start of the first chapter")
        let characters = Array(doc.text)
        let introduction = try XCTUnwrap(map.chapters.dropFirst().first)
        XCTAssertEqual(String(characters[introduction.startChar...].prefix(12)), "Introduction")
        XCTAssertEqual(map.chapters.first?.endChar, introduction.startChar)
    }

    func testNeighbouringTitlePagesBeforeTheFirstChapter() throws {
        let numbered = sections(["1 Introduction", "2 Methods"], level: 2)
        let rows: [(String, [StructuredDocumentLine], [String])] = [
            ("no abstract label: the title page folds into the first chapter",
             titlePage + numbered, ["1 Introduction", "2 Methods"]),
            ("upper case label", titlePage + abstract("ABSTRACT") + numbered, ["ABSTRACT", "1 Introduction", "2 Methods"]),
            ("letter-spaced label", titlePage + abstract("A B S T R A C T") + numbered, ["ABSTRACT", "1 Introduction", "2 Methods"]),
            ("label with a colon", titlePage + abstract("Abstract:") + numbered, ["Abstract", "1 Introduction", "2 Methods"]),
            ("label with spaces around it", titlePage + abstract("  Abstract  ") + numbered, ["Abstract", "1 Introduction", "2 Methods"]),
            ("Summary label", titlePage + abstract("Summary") + numbered, ["Summary", "1 Introduction", "2 Methods"]),
            ("the label is already a heading", titlePage + abstract("Abstract", role: .heading) + numbered,
             ["Abstract", "1 Introduction", "2 Methods"]),
            ("a sentence that starts with Summary is prose, not a label",
             titlePage + abstract("Summary statistics are reported below for every cohort we studied.") + numbered,
             ["Front Matter", "1 Introduction", "2 Methods"]),
            ("a run-in label is prose too", titlePage + abstract("Abstract—We study how AI R&D is automated.") + numbered,
             ["Front Matter", "1 Introduction", "2 Methods"]),
            ("an unlabelled abstract stays Front Matter", titlePage + abstract("We study how AI R&D is automated and what follows.") + numbered,
             ["Front Matter", "1 Introduction", "2 Methods"]),
            ("text before the label stays Front Matter",
             titlePage + [StructuredDocumentLine(text: "Highlights of this working paper for busy readers.", role: .body, pageIndex: 1)]
                + abstract("Abstract") + numbered,
             ["Front Matter", "1 Introduction", "2 Methods"]),
            ("an Abstract line after the first chapter is not a chapter",
             titlePage + sections(["1 Introduction"], level: 2) + abstract("Abstract") + sections(["2 Methods"], level: 2),
             ["1 Introduction", "2 Methods"]),
            ("no title page: the first heading starts at zero",
             sections(["1 Introduction", "2 Methods"], level: 2), ["1 Introduction", "2 Methods"]),
        ]
        for (name, lines, expected) in rows {
            let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: document(lines), title: paperTitle, itemId: "item"), name)
            XCTAssertEqual(map.chapters.map(\.title), expected, name)
            XCTAssertEqual(map.chapters.first?.startChar, 0, name)
        }
    }

    func testAbstractChapterTakesTheShallowestHeadingLevel() throws {
        // Five level-2 sections make level 2 the chapter level; an Abstract at a deeper level
        // would be left out, and the abstract would be heard as part of the title page again.
        let five = sections(["1 Introduction", "2 Background", "3 Methods", "4 Results", "5 Discussion"], level: 2)
        let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(
            for: document(titlePage + abstract("Abstract") + sections(["Notation"], level: 3, page: 1) + five),
            title: paperTitle, itemId: "item"))
        XCTAssertEqual(map.chapters.first?.title, "Abstract")
        XCTAssertEqual(map.chapters.count, 6)
    }

    func testTheAbstractChapterNeverChangesTheChapterDepth() throws {
        // Review of the first fix: counting the Abstract as a heading tipped four level-2
        // sections over the five-chapter depth rule, and their subsections were dropped.
        let nested = (1...4).flatMap { n in
            sections(["\(n) Section"], level: 2) + sections(["\(n).1 Part", "\(n).2 Part"], level: 3)
        }
        let nestedTitles = (1...4).flatMap { ["\($0) Section", "\($0).1 Part", "\($0).2 Part"] }
        let five = sections(["1 Introduction", "2 Background", "3 Methods", "4 Results", "5 Discussion"], level: 2)
        let contents = ["Contents", "1 Introduction ..... 2", "2 Methods ..... 3"].map {
            StructuredDocumentLine(text: $0, role: .frontMatter, pageIndex: 1)
        }
        let numbered = sections(["1 Introduction", "2 Methods"], level: 2)
        let rows: [(String, [StructuredDocumentLine], [String])] = [
            ("four sections with subsections keep their subsections",
             titlePage + abstract("Abstract") + nested, ["Abstract"] + nestedTitles),
            ("an Abstract heading deeper than the chapter level still starts the chapters",
             titlePage + abstract("Abstract", role: .heading) + five,
             ["Abstract", "1 Introduction", "2 Background", "3 Methods", "4 Results", "5 Discussion"]),
            ("a contents page is front matter, not title page",
             contents + numbered, ["Front Matter", "1 Introduction", "2 Methods"]),
            ("a contents page after the title page is front matter too",
             titlePage + contents + numbered, ["Front Matter", "1 Introduction", "2 Methods"]),
            ("TABLE OF CONTENTS in capitals",
             titlePage + [StructuredDocumentLine(text: "TABLE OF CONTENTS", role: .frontMatter, pageIndex: 1)] + Array(contents.dropFirst()) + numbered,
             ["Front Matter", "1 Introduction", "2 Methods"]),
        ]
        for (name, lines, expected) in rows {
            let map = try XCTUnwrap(StructuredDocumentImport.listeningMap(for: document(lines), title: paperTitle, itemId: "item"), name)
            XCTAssertEqual(map.chapters.map(\.title), expected, name)
            XCTAssertEqual(map.chapters.first?.startChar, 0, name)
        }
    }
}
