import Foundation
import XCTest
@testable import SessionKit

/// #3777 PR 2: the planner reads a matched footnote where it is cited. The marker is silent, an aside chunk follows
/// the citing sentence, and the note's definition in the notes section becomes its own chunks. Without `asides`, and
/// for an article with no matched note, the plan is the one prepared audio was always saved with.
final class NarrationFootnotePlanTests: XCTestCase {
    private typealias Planner = NarrationChunkPlanner

    private let tides = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    """

    private func asideChunks(_ plan: Planner.ArticlePlan) -> [Planner.Chunk] {
        plan.chunks.filter { if case .aside = $0.footnote { true } else { false } }
    }

    private func bodyChunks(_ plan: Planner.ArticlePlan) -> [Planner.Chunk] {
        plan.chunks.filter { if case .aside = $0.footnote { false } else { true } }
    }

    private func squashed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    // MARK: - Nothing changes without asides, or without a matched note

    func testWithoutAsidesThePlanIsByteIdenticalToToday() {
        XCTAssertEqual(Planner.articlePlan(tides, asides: false), Planner.articlePlan(tides))
        XCTAssertEqual(Planner.articlePlan(tides).identity, Planner.identity(ofArticle: tides))
        XCTAssertTrue(Planner.articlePlan(tides).chunks.allSatisfy { $0.footnote == nil })
        XCTAssertTrue(Planner.articlePlan(tides).normalizedText.contains("footnote 1"), "today the marker is spoken")
    }

    func testAnArticleWithNoMatchedNoteKeepsItsPlanAndItsIdentity() {
        let texts = [
            "Plain prose. Another sentence of it. And a third one to be sure.",
            "A claim.[^1] No definition for it anywhere.",
            "A claim with no citation.\n\n[^1]: A definition nobody cites.",
            "Defined twice.[^1]\n\n[^1]: First.\n\n[^1]: Second.",
            "A style that is not a footnote [3] at all."
        ]
        for text in texts {
            XCTAssertEqual(Planner.articlePlan(text, asides: true), Planner.articlePlan(text), text)
            XCTAssertEqual(Planner.identity(ofArticle: text, asides: true), Planner.identity(ofArticle: text), text)
        }
    }

    func testAPDFShapedItemHasNoAsides() {
        let pdf = "Results improved on every benchmark. The method is simple and fast.1 Footnotes sit at the page foot.\n\n1 Smith 2020."
        XCTAssertEqual(Planner.articlePlan(pdf, asides: true), Planner.articlePlan(pdf))
        XCTAssertTrue(Planner.silencedCitationRanges(inArticle: pdf).isEmpty)
    }

    func testTheIdentityHashesTheAsidesOnlyWhenTheyAreInThePlan() {
        let plain = Planner.identity(ofArticle: tides)
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertNotEqual(plain, inline)
        XCTAssertEqual(Planner.identity(ofArticle: tides, asides: false), plain)
        XCTAssertEqual(Planner.articlePlan(tides, asides: true).identity, inline)
        XCTAssertNotEqual(Planner.identity(ofArticle: tides + " ", asides: true), inline)
    }

    // MARK: - Markers and asides

    func testAMatchedMarkerIsSilentAndAnUnmatchedOneIsStillSpoken() {
        let text = "One matched claim.[^1] One unmatched claim.[^7] Done.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        XCTAssertFalse(plan.normalizedText.contains("footnote 1 Done"))
        XCTAssertTrue(plan.normalizedText.hasPrefix("One matched claim. One unmatched claim."))
        XCTAssertTrue(plan.normalizedText.contains("footnote 7"), "an unmatched citation keeps today's spoken marker")
        XCTAssertEqual(asideChunks(plan).count, 1)
    }

    func testTheAsideFollowsTheCitingSentenceWhenTheMarkerSitsAfterItsFullStop() throws {
        let plan = Planner.articlePlan(tides, asides: true)
        let asides = asideChunks(plan)
        XCTAssertEqual(asides.map(\.text), ["Note 1. Smith, Tides, 2020.", "Note 2. Lee, Boats, 2021."])
        XCTAssertEqual(asides.map(\.footnote), [.aside("1"), .aside("2")])
        XCTAssertTrue(asides.allSatisfy { $0.sourceLength == 0 })
        let normalized = Array(plan.normalizedText)
        let first = try XCTUnwrap(asides.first)
        XCTAssertEqual(String(normalized[..<first.startOffset]), "The tide turns twice a day.")
        let second = try XCTUnwrap(asides.last)
        XCTAssertTrue(String(normalized[..<second.startOffset]).hasSuffix("Boats wait for it."))
        // The aside sits between the chunk that ends the sentence and the chunk that follows it.
        let firstPosition = try XCTUnwrap(plan.chunks.firstIndex(of: first))
        XCTAssertEqual(plan.chunks[firstPosition - 1].startOffset + plan.chunks[firstPosition - 1].sourceLength, first.startOffset)
        XCTAssertEqual(plan.chunks[firstPosition + 1].startOffset, first.startOffset)
    }

    func testAMarkerInTheMiddleOfASentenceReadsItsNoteAfterTheSentenceNotAtTheMarker() throws {
        let text = "The tide[^1] turns twice a day. It rests.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = try XCTUnwrap(asideChunks(plan).first)
        XCTAssertEqual(String(Array(plan.normalizedText)[..<aside.startOffset]), "The tide turns twice a day.")
        XCTAssertEqual(plan.normalizedText.prefix(12), "The tide tur", "the join leaves one space")
    }

    func testTwoNotesInOneSentenceAreReadInTheOrderTheyAreCited() throws {
        let text = "Two sources agree[^b] and a third does too[^a]. Then more.\n\n[^a]: Note A.\n[^b]: Note B."
        let plan = Planner.articlePlan(text, asides: true)
        let asides = asideChunks(plan)
        XCTAssertEqual(asides.map(\.text), ["Note b. Note B.", "Note a. Note A."])
        XCTAssertEqual(Set(asides.map(\.startOffset)).count, 1, "both after the same sentence")
        XCTAssertEqual(String(Array(plan.normalizedText)[..<asides[0].startOffset]), "Two sources agree and a third does too.")
    }

    func testALaterCitationOfTheSameNoteIsSilentAndAddsNoSecondAside() {
        let text = "First claim.[^1] Middle sentence. Same source again.[^1] End.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        XCTAssertEqual(asideChunks(plan).count, 1)
        XCTAssertTrue(plan.chunks.filter { $0.footnote == nil }.allSatisfy { !$0.text.contains("footnote") }, "no marker is spoken in the body")
    }

    func testANoteWithNothingToSayHasNoAsideButItsMarkerStaysSilent() {
        let text = "A claim.[^1] Another sentence.\n\n[^1]: <img src=\"figure.png\">"
        let plan = Planner.articlePlan(text, asides: true)
        XCTAssertTrue(asideChunks(plan).isEmpty)
        XCTAssertFalse(plan.normalizedText.contains("footnote 1 Another"))
    }

    func testTheLeadSaysTheNumberOrLetterAndNeverSpellsALongLabel() {
        func lead(_ label: String) -> String? {
            let text = "A claim.[^\(label)] More.\n\n[^\(label)]: The note."
            return Planner.articlePlan(text, asides: true).chunks.first { $0.footnote == .aside(label) }?.text
        }
        XCTAssertEqual(lead("3"), "Note 3. The note.")
        XCTAssertEqual(lead("a"), "Note a. The note.")
        XCTAssertEqual(lead("note-3"), "Note 3. The note.")
        XCTAssertEqual(lead("a-long-label"), "Note. The note.")
    }

    func testALongNoteIsSplitIntoAsideChunksThatFitTheBudget() {
        let note = (1...30).map { "Sentence \($0) of a very long note that goes on." }.joined(separator: " ")
        let text = "A claim.[^1] More.\n\n[^1]: \(note)"
        let plan = Planner.articlePlan(text, asides: true)
        let asides = asideChunks(plan)
        XCTAssertGreaterThan(asides.count, 3)
        XCTAssertEqual(Set(asides.map(\.startOffset)).count, 1)
        for chunk in plan.chunks {
            XCTAssertLessThanOrEqual(chunk.text.reduce(0) { $0 + RenderedSpeechChunker.spokenCost(of: $1) }, RenderedSpeechChunker.spokenCostBudget + 8, chunk.text)
        }
        XCTAssertEqual(squashed(asides.map(\.text).joined()), squashed("Note 1. " + note))
    }

    // MARK: - The body is never dropped, and the definitions are their own chunks

    func testEveryBodyCharacterIsInExactlyOneNonAsideChunk() {
        let plan = Planner.articlePlan(tides, asides: true)
        let body = bodyChunks(plan)
        XCTAssertEqual(squashed(body.map(\.text).joined()), squashed(plan.normalizedText))
        XCTAssertEqual(body.first?.startOffset, 0)
        for pair in zip(body, body.dropFirst()) {
            XCTAssertEqual(pair.0.startOffset + pair.0.sourceLength, pair.1.startOffset, "no gap and no overlap")
        }
        XCTAssertEqual(plan.chunks.map(\.index), Array(plan.chunks.indices))
    }

    func testEachMatchedDefinitionIsReadOnceAsAnAsideAndOnceAsDefinitionChunks() {
        let plan = Planner.articlePlan(tides, asides: true)
        for (label, note) in [("1", "Smith, Tides, 2020."), ("2", "Lee, Boats, 2021.")] {
            let asideText = plan.chunks.filter { $0.footnote == .aside(label) }.map(\.text).joined(separator: " ")
            let definitionText = plan.chunks.filter { $0.footnote == .definition(label) }.map(\.text).joined(separator: " ")
            XCTAssertEqual(squashed(asideText), squashed("Note \(label). \(note)"))
            XCTAssertTrue(squashed(definitionText).hasSuffix(squashed(note)), definitionText)
            XCTAssertEqual(plan.chunks.filter { $0.text.contains(note) }.count, 2, "once as aside, once as definition")
        }
        XCTAssertTrue(bodyChunks(plan).filter { $0.footnote == nil }.allSatisfy { !$0.text.contains("Smith") && !$0.text.contains("Lee,") })
    }

    func testAnUnmatchedDefinitionStaysAPlainChunkReadInTheNotesChapter() {
        let text = "A claim.[^1] More.\n\n[^1]: Matched note.\n[^9]: Nobody cites this."
        let plan = Planner.articlePlan(text, asides: true)
        let unmatched = plan.chunks.filter { $0.text.contains("Nobody cites this") }
        XCTAssertEqual(unmatched.count, 1)
        XCTAssertNil(unmatched.first?.footnote)
        XCTAssertEqual(plan.chunks.filter { $0.footnote == .definition("1") }.count, 1)
    }

    func testNoBodyChunkCrossesTheEndOfACitingSentence() {
        let sentence = "The first sentence is long enough that the chunker alone would run it into the next one"
        let text = "\(sentence).[^1] And the next sentence starts right here and runs on a little.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = asideChunks(plan)[0]
        for chunk in bodyChunks(plan) {
            XCTAssertFalse(chunk.startOffset < aside.startOffset && aside.startOffset < chunk.startOffset + chunk.sourceLength)
        }
    }

    // MARK: - Chapters, paragraphs and the end of the text

    func testACitationInAParagraphsLastSentenceReadsBeforeTheNextParagraphsFirstChunk() throws {
        let text = "## One\n\nThe chapter ends on a claim.[^1]\n\n## Two\n\nThe next chapter begins here.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = try XCTUnwrap(asideChunks(plan).first)
        let position = try XCTUnwrap(plan.chunks.firstIndex(of: aside))
        XCTAssertTrue(plan.chunks[position - 1].text.hasSuffix("claim."))
        XCTAssertTrue(plan.chunks[position + 1].text.contains("Two"), plan.chunks[position + 1].text)
    }

    func testAMarkerWithNoFullStopAfterItStopsAtTheEndOfItsParagraph() throws {
        let text = "## Heading with a note[^1]\n\nThe body starts here.\n\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = try XCTUnwrap(asideChunks(plan).first)
        let before = String(Array(plan.normalizedText)[..<aside.startOffset])
        XCTAssertTrue(before.hasSuffix("Heading with a note"), before)
    }

    func testACitationInTheLastSentenceOfTheBodyReadsBeforeTheNotesAreRead() throws {
        let text = "Only one sentence.[^1]\n[^1]: The note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = try XCTUnwrap(asideChunks(plan).first)
        let position = try XCTUnwrap(plan.chunks.firstIndex(of: aside))
        XCTAssertEqual(plan.chunks[position - 1].text, "Only one sentence.")
        XCTAssertEqual(plan.chunks[position + 1].footnote, .definition("1"))
    }

    /// The player maps an offset to the chunk that holds it, so an aside's offset must be where a chunk ends and the
    /// next one starts, and the body chunks must still tile the text.
    private func assertAsidesSitOnChunkEdges(_ plan: Planner.ArticlePlan, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let body = bodyChunks(plan)
        for aside in asideChunks(plan) {
            XCTAssertTrue(body.contains { $0.startOffset + $0.sourceLength == aside.startOffset }, "no chunk ends at the aside's offset in: \(text)", file: file, line: line)
            XCTAssertTrue(body.contains { $0.startOffset == aside.startOffset } || aside.startOffset == plan.normalizedText.count,
                          "no chunk starts at the aside's offset in: \(text)", file: file, line: line)
            XCTAssertFalse(body.contains { $0.startOffset < aside.startOffset && aside.startOffset < $0.startOffset + $0.sourceLength },
                           "a body chunk crosses the aside in: \(text)", file: file, line: line)
        }
        for pair in zip(body, body.dropFirst()) {
            XCTAssertEqual(pair.0.startOffset + pair.0.sourceLength, pair.1.startOffset, "gap in: \(text)", file: file, line: line)
        }
    }

    func testAnAsideSitsOnAChunkEdgeWhenTheNotesFollowRightAfterTheCitingSentence() {
        for text in [
            "Only one sentence.[^1]\n[^1]: The note.",
            "Claim one.[^1] Claim two.[^2]\n\n[^1]: N1.\n[^2]: N2.",
            "Claim one.[^1] Claim two.[^2]\n[^1]: N1.\n[^2]: N2.",
            "A claim.[^1]   \n\n  [^1]: The note.",
            "A first claim.[^1] A second claim.[^2] A third.\n\n## Notes\n\n[^1]: N1.\n[^2]: N2."
        ] {
            assertAsidesSitOnChunkEdges(Planner.articlePlan(text, asides: true), text)
        }
    }

    func testAMarkerOnAHeadingOrListLineStopsAtTheEndOfThatLine() throws {
        let cases: [(text: String, before: String)] = [
            ("## Title[^1]\nBody text. More.\n\n[^1]: Note.", "## Title"),
            ("- item one[^1]\n- item two is here.\n\n[^1]: Note.", "- item one"),
            ("1. item one[^1]\n2. item two is here.\n\n[^1]: Note.", "1. item one"),
            ("> a quote[^1]\nBody text. More.\n\n[^1]: Note.", "> a quote"),
            ("A line that is not finished[^1]\n## Next heading\nBody.\n\n[^1]: Note.", "A line that is not finished")
        ]
        for (text, before) in cases {
            let plan = Planner.articlePlan(text, asides: true)
            let aside = try XCTUnwrap(asideChunks(plan).first, text)
            XCTAssertEqual(String(Array(plan.normalizedText)[..<aside.startOffset]), before, text)
            assertAsidesSitOnChunkEdges(plan, text)
        }
    }

    func testAHardWrappedSentenceKeepsItsNoteUntilItsFullStop() throws {
        let text = "A sentence wrapped[^1]\nacross two lines. Then more.\n\n[^1]: Note."
        let plan = Planner.articlePlan(text, asides: true)
        let aside = try XCTUnwrap(asideChunks(plan).first)
        XCTAssertEqual(String(Array(plan.normalizedText)[..<aside.startOffset]), "A sentence wrapped across two lines.")
    }

    // MARK: - The player's plan

    func testThePlayersPlanCarriesTheAsidesAfterAPrefaceAndMatchesTheArticlePlan() throws {
        let preface = "Overview. A short piece about the tide and the boats that wait for it.\n\n"
        let silenced = Planner.silencedCitationRanges(inArticle: tides).map { ($0.lowerBound + preface.count)..<($0.upperBound + preface.count) }
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(preface + tides, silencingSourceRanges: silenced)
        let start = projection.spokenCharacterOffset(atOrAfterSourceOffset: preface.count)
        let spoken = Planner.spokenPlan(spokenText: projection.text, articleText: tides, articleSpokenStart: start, asides: true)
        let article = Planner.articlePlan(tides, asides: true)
        XCTAssertEqual(spoken.articleIdentity, article.identity)
        let body = spoken.chunks.filter { $0.articleIndex != nil }
        XCTAssertEqual(body.map(\.articleIndex), article.chunks.map(\.index))
        XCTAssertEqual(body.map { $0.startOffset - start }, article.chunks.map(\.startOffset))
        XCTAssertEqual(body.map(\.text), article.chunks.map(\.text))
        XCTAssertEqual(body.map(\.footnote), article.chunks.map(\.footnote))
        XCTAssertTrue(spoken.chunks.filter { $0.articleIndex == nil }.allSatisfy { $0.footnote == nil && $0.startOffset < start })
        XCTAssertEqual(spoken.chunks.filter { if case .aside = $0.footnote { true } else { false } }.count, 2)
    }

    func testASpokenTextThatStillSpeaksTheMarkersMatchesNoArticlePlanWithAsides() {
        let spoken = Planner.spokenPlan(
            spokenText: SpeechTextNormalizer.normalize(tides), articleText: tides, articleSpokenStart: 0, asides: true)
        XCTAssertNil(spoken.articleIdentity)
        XCTAssertTrue(spoken.chunks.allSatisfy { $0.footnote == nil && $0.articleIndex == nil })
    }

    func testThePlayersPlanWithoutAsidesIsUnchangedForAFootnotedArticle() {
        let spoken = Planner.spokenPlan(
            spokenText: SpeechTextNormalizer.normalize(tides), articleText: tides, articleSpokenStart: 0)
        XCTAssertEqual(spoken.articleIdentity, Planner.identity(ofArticle: tides))
        XCTAssertTrue(spoken.chunks.allSatisfy { $0.footnote == nil && $0.articleIndex != nil })
    }

    // MARK: - Silencing, and a long source

    func testSilencingKeepsEveryOtherCharacterMappedToItsOwnOffset() {
        let source = "Word[^1]word, then a [^2] gap."
        let plain = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        XCTAssertEqual(SpeechTextNormalizer.normalizeWithSourceOffsets(source, silencingSourceRanges: []), plain)
        let first = 4..<8
        let second = 21..<25
        let silenced = SpeechTextNormalizer.normalizeWithSourceOffsets(source, silencingSourceRanges: [second, first])
        XCTAssertEqual(silenced.text, "Word word, then a gap.")
        let characters = Array(source)
        for (index, offset) in silenced.sourceOffsets.enumerated() where silenced.text.map({ $0 })[index] != " " {
            XCTAssertEqual(characters[offset], Array(silenced.text)[index])
        }
        XCTAssertEqual(silenced.sourceLength, source.count)
    }

    func testALongSourceWithManyNotesPlansQuicklyAndWithinTheBudget() {
        let body = (1...150).map { "Claim number \($0) is made here.[^\($0)] It is explained a little." }.joined(separator: " ")
        let notes = (1...150).map { "[^\($0)]: Source number \($0), a reference with a title and a year, 2020." }.joined(separator: "\n")
        let text = body + "\n\n## Notes\n\n" + notes
        let started = Date()
        let plan = Planner.articlePlan(text, asides: true)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(asideChunks(plan).count, 150)
        XCTAssertEqual(plan.chunks.filter { if case .definition = $0.footnote { true } else { false } }.isEmpty, false)
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.55 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a planner that rescans the notes per claim.
        XCTAssertLessThan(elapsed, 5, "planning 150 notes must not scale badly")
        for chunk in plan.chunks {
            XCTAssertLessThanOrEqual(chunk.text.reduce(0) { $0 + RenderedSpeechChunker.spokenCost(of: $1) }, RenderedSpeechChunker.spokenCostBudget + 8)
        }
    }
}
