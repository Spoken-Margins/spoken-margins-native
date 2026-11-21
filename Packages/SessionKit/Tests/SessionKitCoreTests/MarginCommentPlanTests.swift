import Foundation
import XCTest
@testable import SessionKit

/// #4338: which sentence each own Margin comments on, which page to look on first, and the words the comment carries.
final class MarginCommentPlanTests: XCTestCase {
    private let itemId = "item-1"

    private func document(_ text: String, segments: [(start: Int, length: Int, page: Int?)] = []) -> StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 3, textSHA256: nil),
            text: text,
            segments: segments.enumerated().map { index, segment in
                .init(id: "s\(index)", role: .body, range: .init(start: segment.start, length: segment.length), pageIndex: segment.page)
            },
            markers: []
        )
    }

    private func margin(
        _ id: String = "m1",
        at startChar: Int,
        endChar: Int? = nil,
        itemId: String? = nil,
        anchorType: AnchorType = .text,
        transcript: String? = nil,
        cleaned: String? = nil,
        display: String? = nil,
        transcription: String = "transcribed",
        written: Bool = false,
        status: String = "active",
        createdAt: Double = 1
    ) -> Interjection {
        Interjection(
            id: id, itemId: itemId ?? self.itemId, sessionId: "session-1", targetType: .item, targetId: itemId ?? self.itemId,
            createdAt: Date(timeIntervalSince1970: createdAt), roughPercent: 0,
            anchor: Anchor(anchorType: anchorType, startChar: startChar, endChar: endChar ?? startChar + 1, anchorBefore: "", anchorAfter: ""),
            audioPath: written ? nil : "\(id).m4a", audioStatus: written ? "none" : "ready", transcriptionStatus: transcription,
            transcript: transcript, cleanedTranscript: cleaned, displayText: display, status: status,
            captureKind: written ? .written : .audio
        )
    }

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: needle), "\(needle) is not in the text")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// The sentence the plan picks for a Margin anchored on `anchor`'s first character.
    private func sentence(in text: String, anchoredAt anchor: String) throws -> String {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text),
            margins: [margin(at: try offset(of: anchor, in: text), transcript: "x")]
        )
        return try XCTUnwrap(plan.entries.first).sentenceText
    }

    // MARK: A text item with no pages (a Word document, #4595)

    func testATextItemPlansTheSameSentencesWithNoPageNeverAPageOfTheDocument() throws {
        let text = "Intro line here.\n\nSleep helps memory. It also helps mood."
        let anchor = try offset(of: "It also", in: text)
        let margins = [margin("a", at: 0, transcript: "first"), margin("b", at: anchor, transcript: "second")]
        let plain = MarginCommentPlan.make(itemId: itemId, text: text, margins: margins)
        let paged = MarginCommentPlan.make(itemId: itemId, document: document(text, segments: [(0, text.count, 1)]), margins: margins)
        XCTAssertEqual(plain.entries.map(\.sentenceText), ["Intro line here.", "It also helps mood."])
        XCTAssertEqual(plain.entries.map(\.commentText), ["first", "second"])
        XCTAssertEqual(plain.entries.map(\.precedingText), paged.entries.map(\.precedingText))
        XCTAssertEqual(plain.entries.map(\.pageIndex), [nil, nil])
        XCTAssertEqual(paged.entries.map(\.pageIndex), [1, 1], "the paged variant still reports a page")
    }

    func testATextItemKeepsOnlyOwnActiveMarginsAndNamesPendingOnes() throws {
        let text = "One sentence. Another sentence."
        let margins = [
            margin("own", at: 0, transcript: "mine"),
            margin("other-item", at: 0, itemId: "item-2", transcript: "elsewhere"),
            margin("gone", at: 0, transcript: "deleted", status: "deleted"),
            margin("pending", at: 15, transcription: "pending"),
        ]
        let plan = MarginCommentPlan.make(itemId: itemId, text: text, margins: margins)
        XCTAssertEqual(plan.entries.map(\.marginId), ["own", "pending"])
        XCTAssertEqual(plan.entries.map(\.status), [.included, .transcriptPending])
        XCTAssertEqual(MarginCommentPlan.make(itemId: itemId, text: "", margins: margins).entries.map(\.sentenceText), ["", ""])
    }

    // MARK: The sentence

    func testTheSentenceAroundTheAnchorTable() throws {
        let rows: [(name: String, text: String, anchor: String, expected: String)] = [
            ("mid-sentence", "First one. The effect held in every cohort. Last one.", "held", "The effect held in every cohort."),
            ("at a sentence's first character", "First one. The effect held. Last one.", "The effect", "The effect held."),
            ("on a sentence's last character", "First one. The effect held. Last one.", "held.", "The effect held."),
            ("the last sentence, no full stop", "First one. The effect held in every cohort", "cohort", "The effect held in every cohort"),
            ("the first sentence", "First one. Second one.", "First", "First one."),
            ("an abbreviation inside", "as shown in Fig. 3, the effect held. Then it fell.", "effect", "as shown in Fig. 3, the effect held."),
            ("a figure reference with a capital after", "See Fig. 3 for more. Then it fell.", "more", "See Fig. 3 for more."),
            ("e.g. and a new sentence", "Use a nap, e.g. sleep. Then wake.", "nap", "Use a nap, e.g. sleep."),
            ("the sentence after e.g.", "Use a nap, e.g. sleep. Then wake.", "wake", "Then wake."),
            ("i.e.", "It held, i.e. it did not fall. Next.", "fall", "It held, i.e. it did not fall."),
            ("et al.", "Smith et al. Found a gap. Next.", "gap", "Smith et al. Found a gap."),
            ("Dr.", "Dr. Jones agreed. Next.", "agreed", "Dr. Jones agreed."),
            ("vs.", "Drug vs. Placebo was close. Next.", "close", "Drug vs. Placebo was close."),
            ("an initial", "J. Smith wrote it. Next.", "wrote", "J. Smith wrote it."),
            ("U.S.", "The U.S. Army agreed. Next.", "agreed", "The U.S. Army agreed."),
            ("a single lowercase letter ends the sentence", "Pick option a. Then go on.", "Then", "Then go on."),
            ("a question mark", "Did it hold? Yes it did! Fine.", "Yes", "Yes it did!"),
            ("an ellipsis character", "It held… Then it fell. Done.", "fell", "Then it fell."),
            ("three dots", "It held... Then it fell. Done.", "held", "It held..."),
            ("a digit starts the next sentence", "It held. 12 mice fell. Done.", "mice", "12 mice fell."),
            ("a decimal is not an end", "The mean was 3.5 units. Next.", "units", "The mean was 3.5 units."),
            ("milliseconds end a sentence", "It took 250 ms. Then it fell.", "fell", "Then it fell."),
            ("seconds end a sentence", "Wait 3 sec. Then go.", "go", "Then go."),
            ("a bare p ends a sentence", "We set p. Then we ran.", "ran", "Then we ran."),
            ("Tab. before a number", "See Tab. 2 for details. Next.", "details", "See Tab. 2 for details."),
            ("No. before a number", "Order No. 5 shipped. Next.", "shipped", "Order No. 5 shipped."),
            ("No. before a word ends", "I said no. Then I left.", "left", "Then I left."),
            ("St. as a name", "Louis St. Clair spoke. Next.", "spoke", "Louis St. Clair spoke."),
            ("Ms. as a title", "Ms. Lee agreed. Next.", "agreed", "Ms. Lee agreed."),
            ("a lowercase word after a full stop is the same sentence", "See p. 4 for details. Next.", "details", "See p. 4 for details."),
            ("curly quotes closing", "She said “it held.” Then it fell. Done.", "held", "She said “it held.”"),
            ("curly quotes opening", "She said “it held.” “Then it fell,” he said. Done.", "Then", "“Then it fell,” he said."),
            ("straight quotes and a bracket", "It held (see below.) Then it fell. Done.", "see", "It held (see below.)"),
            ("a paragraph break ends a sentence with no full stop", "A heading\n\nthe body goes on. Next.", "heading", "A heading"),
            ("the sentence after a paragraph break", "A heading\n\nthe body goes on. Next.", "body", "the body goes on."),
            ("hard line breaks stay inside a sentence", "The effect\nheld in every\ncohort. Next.", "held", "The effect\nheld in every\ncohort."),
            ("a sentence across a hard line break after a stop", "It held.\nThen it fell. Done.", "fell", "Then it fell."),
            ("CRLF paragraph break", "A heading\r\n\r\nthe body goes on. Next.", "body", "the body goes on."),
            ("leading and trailing space", "  First one.   The effect held.  ", "effect", "The effect held."),
        ]
        for row in rows {
            XCTAssertEqual(try sentence(in: row.text, anchoredAt: row.anchor), row.expected, row.name)
        }
    }

    func testNFCAndNFDSpellingsPickTheSameSentence() throws {
        let nfc = "Caf\u{E9} life. The caf\u{E9} was shut. Next."
        let nfd = "Cafe\u{301} life. The cafe\u{301} was shut. Next."
        XCTAssertNotEqual(Array(nfc.utf16), Array(nfd.utf16))
        let fromNFC = try sentence(in: nfc, anchoredAt: "was")
        let fromNFD = try sentence(in: nfd, anchoredAt: "was")
        XCTAssertEqual(fromNFC.precomposedStringWithCanonicalMapping, fromNFD.precomposedStringWithCanonicalMapping)
        XCTAssertEqual(fromNFC, "The caf\u{E9} was shut.")
        // The anchors count Characters, so the same offset lands on the same words in both spellings.
        let offsetInNFC = try offset(of: "was", in: nfc)
        XCTAssertEqual(try offset(of: "was", in: nfd), offsetInNFC)
        let plan = MarginCommentPlan.make(itemId: itemId, document: document(nfd), margins: [margin(at: offsetInNFC, transcript: "x")])
        XCTAssertEqual(plan.entries.first?.sentence, 11..<29, "range is in Characters, not UTF-16 units")
    }

    func testAnEndCharPastTheTextEndChangesNothing() throws {
        let text = "First one. The effect held."
        let start = try offset(of: "effect", in: text)
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text),
            margins: [margin(at: start, endChar: text.count + 500, transcript: "x")]
        )
        XCTAssertEqual(plan.entries.first?.sentenceText, "The effect held.")
    }

    func testAStartOutsideTheTextIsClampedOntoIt() {
        let text = "First one. The effect held."
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text),
            margins: [margin("before", at: -4, transcript: "a"), margin("after", at: 10_000, transcript: "b")]
        )
        XCTAssertEqual(plan.entries.map(\.sentenceText), ["First one.", "The effect held."])
    }

    func testEachEntryCarriesTheTextJustBeforeItsSentence() throws {
        let long = String(repeating: "Earlier words go on and on. ", count: 8)
        let text = "Opening line. Then the effect held.\n\n" + long + "The last one is here."
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text),
            margins: [
                margin("first", at: 0, transcript: "a"),
                margin("second", at: try offset(of: "Then", in: text), transcript: "b"),
                margin("last", at: try offset(of: "The last", in: text), transcript: "c")
            ]
        )
        XCTAssertEqual(plan.entries.map(\.precedingText.count), [0, "Opening line. ".count, MarginCommentPlan.precedingLength])
        XCTAssertEqual(plan.entries[1].precedingText, "Opening line. ")
        XCTAssertTrue(plan.entries[2].precedingText.hasSuffix("Earlier words go on and on. "))
        let none = MarginCommentPlan.make(itemId: itemId, document: document(""), margins: [margin(at: 0, transcript: "x")])
        XCTAssertEqual(none.entries.first?.precedingText, "")
    }

    func testAStartInTheGapBetweenParagraphsMovesToTheNextWords() throws {
        let text = "First paragraph here.\n\nSecond paragraph here."
        let gap = try offset(of: "\n\n", in: text) + 1
        let plan = MarginCommentPlan.make(itemId: itemId, document: document(text), margins: [margin(at: gap, transcript: "x")])
        XCTAssertEqual(plan.entries.first?.sentenceText, "Second paragraph here.")
    }

    func testAnEmptyOrBlankDocumentHasNoSentenceButStillPlansTheWords() {
        for text in ["", "  \n\n  "] {
            let plan = MarginCommentPlan.make(itemId: itemId, document: document(text), margins: [margin(at: 0, transcript: "note")])
            XCTAssertNil(plan.entries.first?.sentence)
            XCTAssertEqual(plan.entries.first?.sentenceText, "")
            XCTAssertNil(plan.entries.first?.pageIndex)
            XCTAssertEqual(plan.entries.first?.commentText, "note")
        }
    }

    func testSentenceRangesAreCharacterOffsetsThatSliceTheText() throws {
        let text = "Caf\u{E9}\u{301} 😀 one. Second 😀 here! Third"
        let characters = Array(text)
        let ranges = SentenceBounds.ranges(in: characters)
        XCTAssertEqual(ranges.map { String(characters[$0]) }, ["Caf\u{E9}\u{301} 😀 one.", "Second 😀 here!", "Third"])
        XCTAssertEqual(ranges.map(\.lowerBound), [0, text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "Second")).lowerBound), text.count - 5])
    }

    func testAVeryLongTextWithManyMarginsPlansQuickly() {
        let paragraph = String(repeating: "The effect held in every cohort. ", count: 60)
        let text = Array(repeating: paragraph, count: 600).joined(separator: "\n\n")
        let margins = (0..<200).map { margin("m\($0)", at: $0 * (text.count / 200), transcript: "x") }
        let started = Date()
        let plan = MarginCommentPlan.make(itemId: itemId, document: document(text), margins: margins)
        XCTAssertEqual(plan.entries.count, 200)
        XCTAssertTrue(plan.entries.allSatisfy { $0.sentence != nil })
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.3 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a rescan of the whole text for each Margin's sentence.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: The page

    func testThePageIsTheSegmentTheAnchorSitsIn() throws {
        let text = "Page one text. More of it.\n\nPage two text here.\n\nNo page here."
        let second = try offset(of: "Page two", in: text)
        let third = try offset(of: "No page", in: text)
        let segments = [(start: 0, length: second - 2, page: Optional(0)), (start: second, length: third - 2 - second, page: Optional(1)), (start: third, length: text.count - third, page: Optional<Int>.none)]
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text, segments: segments),
            margins: [
                margin("a", at: 3, transcript: "x"),
                margin("b", at: second + 5, transcript: "x"),
                margin("c", at: third + 1, transcript: "x"),
                margin("gap", at: second - 1, transcript: "x"),
            ]
        )
        let pages = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.marginId, $0.pageIndex) })
        XCTAssertEqual(pages["a"] ?? nil, 0)
        XCTAssertEqual(pages["b"] ?? nil, 1)
        XCTAssertNil(pages["c"] ?? nil, "a segment with no page gives no hint")
        XCTAssertEqual(pages["gap"] ?? nil, 1, "an anchor in the gap moves to the next words, which are on page two")
    }

    func testOverlappingSegmentsGiveTheNarrowestOnesPage() {
        let text = String(repeating: "A sentence goes here. ", count: 50)
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text, segments: [(start: 0, length: 1000, page: 0), (start: 100, length: 10, page: 1)]),
            margins: [margin("outer", at: 500, transcript: "x"), margin("inner", at: 105, transcript: "x")]
        )
        XCTAssertEqual(plan.entries.map(\.pageIndex), [1, 0], "ordered by position: the inner one at 105 first")
    }

    func testAnAnchorNoSegmentCoversHasNoPage() {
        let text = String(repeating: "A sentence goes here. ", count: 10)
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text, segments: [(start: 0, length: 50, page: 0)]),
            margins: [margin("covered", at: 10, transcript: "x"), margin("past", at: 120, transcript: "x")]
        )
        XCTAssertEqual(plan.entries.map(\.pageIndex), [0, nil])
    }

    func testAPageThatIsNotInTheDocumentIsNotAHint() {
        // The test document says it has three pages: 0, 1 and 2.
        for page in [-1, 3, 99] {
            let plan = MarginCommentPlan.make(
                itemId: itemId, document: document("One. Two.", segments: [(start: 0, length: 9, page: page)]),
                margins: [margin(at: 0, transcript: "x")]
            )
            XCTAssertNil(plan.entries.first?.pageIndex, "page \(page)")
        }
        let last = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two.", segments: [(start: 0, length: 9, page: 2)]), margins: [margin(at: 0, transcript: "x")]
        )
        XCTAssertEqual(last.entries.first?.pageIndex, 2)
    }

    func testADocumentWithNoSegmentsHasNoPage() {
        let plan = MarginCommentPlan.make(itemId: itemId, document: document("One. Two."), margins: [margin(at: 0, transcript: "x")])
        XCTAssertNil(plan.entries.first?.pageIndex)
    }

    // MARK: The words and the status

    func testTheCommentTakesTheWordsTheAppShows() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two."),
            margins: [
                margin("display", at: 0, transcript: "raw", cleaned: "clean", display: "  shown  \n"),
                margin("cleaned", at: 1, transcript: "raw", cleaned: "clean"),
                margin("raw", at: 2, transcript: "raw"),
            ]
        )
        XCTAssertEqual(plan.entries.map(\.commentText), ["shown", "clean", "raw"])
        XCTAssertTrue(plan.entries.allSatisfy { $0.status == .included })
    }

    func testAWrittenMarginGoesWithItsOwnWordsWhateverItsTranscriptionStatus() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two."),
            margins: [margin("written", at: 0, display: "A written Margin", transcription: "complete", written: true)]
        )
        XCTAssertEqual(plan.entries.first?.status, .included)
        XCTAssertEqual(plan.entries.first?.commentText, "A written Margin")
    }

    func testASpokenMarginWithoutWordsIsPendingOrHasNoTranscript() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two."),
            margins: [
                margin("pending", at: 0, transcription: "pending"),
                margin("failed", at: 1, transcription: "failed"),
                margin("empty", at: 2, transcript: "", transcription: "transcribed"),
                margin("blank", at: 3, transcript: "  \n ", transcription: "transcribed"),
                margin("pendingBlank", at: 4, transcript: " ", transcription: "pending"),
            ]
        )
        XCTAssertEqual(plan.entries.map(\.status), [.transcriptPending, .noTranscript, .noTranscript, .noTranscript, .transcriptPending])
        XCTAssertTrue(plan.entries.allSatisfy { $0.commentText.isEmpty })
        XCTAssertTrue(plan.included.isEmpty)
        // Left out of the export, but still placed, so the sheet can say where it would land.
        XCTAssertTrue(plan.entries.allSatisfy { $0.sentence != nil })
    }

    func testWordsAlreadyThereCountEvenIfTranscriptionIsMarkedPending() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two."),
            margins: [margin(at: 0, transcript: "heard it", transcription: "pending")]
        )
        XCTAssertEqual(plan.entries.first?.status, .included)
    }

    // MARK: Whose Margins

    func testOnlyOwnActiveTextMarginsOfThisItemArePlanned() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two."),
            margins: [
                margin("mine", at: 0, transcript: "x"),
                margin("other-item", at: 0, itemId: "item-2", transcript: "x"),
                margin("trashed", at: 0, transcript: "x", status: "deleted"),
                margin("a-time-anchor", at: 0, anchorType: .media, transcript: "x"),
                margin("a-turn-anchor", at: 0, anchorType: .turn, transcript: "x"),
            ]
        )
        XCTAssertEqual(plan.entries.map(\.marginId), ["mine"])
    }

    /// A friend's Margins are `ImportedCommentaryLayer` rows, never `Interjection`s, so the plan cannot be handed one;
    /// what it can be handed and must refuse is a Margin on a summary or assistant turn, even with a text anchor.
    func testAMarginOnATurnIsNotPlannedEvenWithATextAnchor() {
        var summary = margin("summary", at: 0, transcript: "x")
        summary.targetType = .summaryTurn
        var assistant = margin("assistant", at: 0, transcript: "x")
        assistant.targetType = .assistantTurn
        let plan = MarginCommentPlan.make(itemId: itemId, document: document("One. Two."), margins: [summary, assistant, margin("item", at: 0, transcript: "x")])
        XCTAssertEqual(plan.entries.map(\.marginId), ["item"])
    }

    func testEntriesComeInDocumentOrderThenCreationOrder() {
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document("One. Two. Three."),
            margins: [
                margin("late", at: 12, transcript: "x", createdAt: 5),
                margin("same-b", at: 6, transcript: "x", createdAt: 2),
                margin("same-a", at: 6, transcript: "x", createdAt: 1),
                margin("tie-z", at: 0, transcript: "x", createdAt: 3),
                margin("tie-y", at: 0, transcript: "x", createdAt: 3),
            ]
        )
        XCTAssertEqual(plan.entries.map(\.marginId), ["tie-y", "tie-z", "same-a", "same-b", "late"])
    }

    func testTwoMarginsOnOneSentenceShareIt() throws {
        let text = "First one. The effect held in every cohort. Last one."
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(text),
            margins: [margin("a", at: try offset(of: "effect", in: text), transcript: "x"), margin("b", at: try offset(of: "cohort", in: text), transcript: "y")]
        )
        XCTAssertEqual(plan.entries[0].sentence, plan.entries[1].sentence)
        XCTAssertEqual(plan.included.map(\.marginId), ["a", "b"])
    }

    // MARK: The PDF rule

    func testThePDFHelperAgreesWithTheLibraryFilterOnEveryNeighbouringRow() {
        let rows: [(name: String, media: String, reference: String?, type: String?, isPDF: Bool)] = [
            ("pdf media type", "pdf", nil, nil, true),
            ("PDF in capitals", "PDF", nil, nil, true),
            ("a .pdf link", "article", "https://example.com/paper.pdf", "url", true),
            ("a .PDF link in capitals", "text", "HTTPS://EXAMPLE.COM/PAPER.PDF", "url", true),
            ("a .pdf link with a query", "text", "https://example.com/paper.pdf?download=1", "url", true),
            ("a plain article", "article", "https://example.com/post", "url", false),
            ("an epub", "epub", nil, nil, false),
            ("a podcast", "podcast", nil, nil, false),
            ("a text file", "text", nil, nil, false),
            ("a transcript named like a pdf", "text", "notes.pdf.txt", TranscriptItemText.referenceType, false),
            ("empty media type", "", nil, nil, false),
        ]
        for row in rows {
            let item = LibraryItemRow(
                id: "i", title: "T", status: "ready", canDelete: true, mediaType: row.media,
                sourceReference: row.reference, sourceReferenceType: row.type
            )
            XCTAssertEqual(LibraryQueryEngine.isPDF(item), row.isPDF, row.name)
            XCTAssertEqual(
                LibraryRowWording.isPDF(mediaType: row.media, sourceReference: row.reference, sourceReferenceType: row.type), row.isPDF, row.name
            )
            XCTAssertEqual(
                LibraryQueryEngine.visibleLibraryItems([item], query: .init(contentType: .pdf, listeningState: .all)).count == 1, row.isPDF,
                "the PDF filter says \(row.name) is\(row.isPDF ? "" : " not") a PDF"
            )
        }
    }
}
