import Foundation
import XCTest
@testable import SessionKit

/// #4339 PR 1: the filler-only tidy and the guard every proposal must pass.
final class MarginTidyTests: XCTestCase {
    func testFillerOnlyTable() {
        let rows: [(name: String, input: String, expected: String)] = [
            ("the Design's example", "um so the the result was not 12 percent", "The result was not 12 percent"),
            ("a leading filler with a comma", "Um, the result was good", "The result was good"),
            ("a filler with no comma mid-sentence", "I think um it works", "I think it works"),
            ("a filler between commas", "the result, um, was good", "the result was good"),
            ("a filler then a full stop", "It held. Um. It fell.", "It held. It fell."),
            ("a filler at the start before a sentence end", "Um. The result held.", "The result held."),
            ("a capital after a removal that follows a sentence end", "It fell. Um it broke.", "It fell. It broke."),
            ("capitals and shouting", "UM the result, ERM, held", "The result held"),
            ("every listed filler", "uhm uh ah ahh er erm um the result held", "The result held"),
            ("an isolated you know between commas", "I was, you know, tired", "I was tired"),
            ("an isolated you know at the start", "You know, it works", "It works"),
            ("an isolated you know at the end", "It works, you know.", "It works."),
            ("do you know is a question", "Do you know the answer", "Do you know the answer"),
            ("do you know, with a comma after", "Do you know, the answer is not obvious", "Do you know, the answer is not obvious"),
            ("you know that, no comma", "it is true, you know that it is", "it is true, you know that it is"),
            ("you know as a question", "You know? It is true", "You know? It is true"),
            ("a repeated word", "the the result held", "the result held"),
            ("a repeated word keeps the first one's capital", "The the result held", "The result held"),
            ("a repeated pronoun", "I I think it held", "I think it held"),
            ("a repeated word mixed case", "THE the result held", "THE result held"),
            ("three in a row", "the the the result held", "the result held"),
            ("a repeat that ends a clause keeps the mark", "it was very very, good", "it was very, good"),
            ("repeated across a comma is kept", "very, very good", "very, very good"),
            ("had had is grammatical", "he had had enough of it", "he had had enough of it"),
            ("that that is grammatical", "I know that that is true", "I know that that is true"),
            ("repeated numbers are kept", "it was 10 10 percent", "it was 10 10 percent"),
            ("a run-up so", "So the result held", "The result held"),
            ("a run-up so with a comma", "So, the result held", "The result held"),
            ("a run-up okay so", "Okay so the result held", "The result held"),
            ("a run-up okay comma so comma", "Okay, so, the result held", "The result held"),
            ("a run-up well with a comma", "Well, it held", "It held"),
            ("well done stays", "Well done by the authors", "Well done by the authors"),
            ("so far stays", "So far the results hold", "So far the results hold"),
            ("so much stays", "So much was said about it", "So much was said about it"),
            ("so on its own stays", "so", "so"),
            ("so only at the very start", "the result was so clear", "the result was so clear"),
            ("a filler then a run-up", "um so the result held", "The result held"),
            ("never removes like, actually, just, right", "it was like, actually just right for the paper", "it was like, actually just right for the paper"),
            ("a filler inside a longer word", "the umbrella was an error in the umpire's view", "the umbrella was an error in the umpire's view"),
            ("fillers with a trailing question mark", "Was it good, er?", "Was it good?"),
            ("nothing to remove is returned untouched, spacing and all", "the result   held,\n and that was it", "the result   held,\n and that was it"),
            ("non-English text is unchanged", "er hat das gemacht und es war gut", "er hat das gemacht und es war gut"),
            ("non-English with accents", "il a dit euh que c'était bien", "il a dit euh que c'était bien"),
            ("empty", "", ""),
            ("blank", "  \n ", "  \n "),
            ("one filler word", "um", "um"),
            ("only fillers", "um uh er", "um uh er"),
            ("one word", "result", "result"),
            ("emoji and accents survive", "um the café was 😀 great", "The café was 😀 great"),
        ]
        for row in rows {
            XCTAssertEqual(MarginTidy.fillerOnly(row.input), row.expected, row.name)
        }
    }

    func testFiveMinutesOfSpeechTidiesAndKeepsEverythingElse() {
        let sentence = "um so the the result held, you know, in every cohort. "
        let text = String(repeating: sentence, count: 90)
        let tidy = MarginTidy.fillerOnly(text)
        XCTAssertFalse(tidy.contains(" um "))
        XCTAssertTrue(tidy.hasPrefix("The result held in every cohort. "))
        XCTAssertEqual(tidy.components(separatedBy: "in every cohort.").count, 91)
        XCTAssertFalse(tidy.lowercased().contains("the the"))
    }

    func testTheFillerOnlyTidyAlwaysPassesTheGuard() {
        for text in [
            "um so the the result was not 12 percent", "I was, you know, tired and Sarah said \"no way\" in Boston",
            "Well, it was never two hundred percent clear that um nothing happened",
        ] {
            let tidy = MarginTidy.fillerOnly(text)
            XCTAssertNotEqual(tidy, text)
            XCTAssertNil(MarginTidyGuard.rejection(original: text, proposal: tidy), text)
        }
    }

    // MARK: The guard

    private let original = "um so I met Sarah in Boston and she said \"no way\" about the 12 percent, it was not two hundred"
    private let good = "I met Sarah in Boston and she said \"no way\" about the 12 percent. It was not two hundred."

    func testAFaithfulRewritePasses() {
        XCTAssertNil(MarginTidyGuard.rejection(original: original, proposal: good))
        XCTAssertTrue(MarginTidyGuard.accepts(original: original, proposal: good))
    }

    func testGuardRejectionsTable() {
        let rows: [(name: String, proposal: String, expected: MarginTidyGuard.Rejection)] = [
            ("a digit number dropped", "I met Sarah in Boston and she said \"no way\" about the percent. It was not two hundred.", .numberMissing("12")),
            ("a number changed", "I met Sarah in Boston and she said \"no way\" about the 12 percent. It was not three hundred.", .numberMissing("two hundred")),
            ("percent dropped", "I met Sarah in Boston and she said \"no way\" about the 12. It was not two hundred.", .numberMissing("percent")),
            ("a name dropped", "I met someone in Boston and she said \"no way\" about the 12 percent. It was not two hundred.", .nameMissing("Sarah")),
            ("a place dropped", "I met Sarah and she said \"no way\" about the 12 percent. It was not two hundred.", .nameMissing("Boston")),
            ("a quotation dropped", "I met Sarah in Boston and she disagreed about the 12 percent. It was not two hundred.", .quotationMissing("no way")),
            ("a quotation reworded", "I met Sarah in Boston and she said \"no chance\" about the 12 percent. It was not two hundred.", .quotationMissing("no way")),
            ("a negation dropped", "I met Sarah in Boston and she said \"no way\" about the 12 percent. It was two hundred.", .negationDropped),
            ("empty", "   ", .emptyProposal),
            ("far too long", good + " " + String(repeating: "And then a good deal more was said about it. ", count: 4), .tooLong),
        ]
        for row in rows {
            XCTAssertEqual(MarginTidyGuard.rejection(original: original, proposal: row.proposal), row.expected, row.name)
            XCTAssertFalse(MarginTidyGuard.accepts(original: original, proposal: row.proposal), row.name)
        }
        XCTAssertEqual(MarginTidyGuard.rejection(original: "", proposal: "text"), .emptyOriginal)
        let rambling = "so I really do think that this was a very long and rambling story about the whole thing at the end of it"
        XCTAssertEqual(MarginTidyGuard.rejection(original: rambling, proposal: "It was a long story."), .tooShort)
        XCTAssertNil(MarginTidyGuard.rejection(original: rambling, proposal: "I think this was a long and rambling story about the whole thing."))
    }

    func testEachNegationWordCountsWhenDropped() {
        for (said, dropped) in [
            ("it was not clear to me", "it was clear to me"), ("no one agreed with it", "one agreed with it"),
            ("it never worked for me", "it worked for me"), ("nothing helped it at all", "something helped it at all"),
            ("none of them agreed with it", "all of them agreed with it"), ("neither of them agreed with it", "both of them agreed with it"),
            ("it was nor good nor bad", "it was good or bad"), ("it ran without any trouble", "it ran with any trouble"),
            ("I can't see how it works", "I can see how it works"), ("they didn't see how it works", "they did see how it works"),
        ] {
            XCTAssertEqual(MarginTidyGuard.rejection(original: said, proposal: dropped), .negationDropped, said)
        }
    }

    func testNegationsMayStayOrGrowAndCantMayBecomeCannot() {
        XCTAssertNil(MarginTidyGuard.rejection(original: "I can't see how it works", proposal: "I cannot see how it works"))
        XCTAssertNil(MarginTidyGuard.rejection(original: "it was not clear to me at all, honestly", proposal: "it was not clear to me at all, never"))
        XCTAssertNil(MarginTidyGuard.rejection(original: "it wasn't clear to me at all, honestly", proposal: "it was not clear to me at all"))
    }

    func testSentenceInitialWordsAreNotNamesButMidSentenceOnesAre() {
        XCTAssertNil(MarginTidyGuard.rejection(original: "Sarah said it was fine. Tom left early", proposal: "She said it was fine. He left early"), "capitalised only at a sentence start")
        XCTAssertEqual(MarginTidyGuard.rejection(original: "we heard it from Tom today", proposal: "we heard it from him today"), .nameMissing("Tom"))
        XCTAssertNil(MarginTidyGuard.rejection(original: "so I think I know it", proposal: "I think I know it"), "the pronoun I is never a name")
    }

    func testQuotedSpansInEveryQuoteStyle() {
        let restyled = ["he said “stop right there” and left", "he said \"stop right there\" and left", "he said “stop right there” and left"]
        for (index, quoted) in ["he said \"stop right there\" and left", "he said “stop right there” and left", "he said 'stop right there' and left"].enumerated() {
            XCTAssertNil(MarginTidyGuard.rejection(original: quoted, proposal: restyled[index]), "a restyled quotation passes: \(quoted)")
        }
        for (quoted, replacement) in [
            ("he said \"stop right there\" and left", "he said stop right there and left"),
            ("he said “stop right there” and left", "he said stop right there and left"),
            ("he said 'stop right there' and left", "he said stop right there and left"),
        ] {
            XCTAssertNotNil(MarginTidyGuard.rejection(original: quoted, proposal: replacement), quoted)
            XCTAssertNil(MarginTidyGuard.rejection(original: quoted, proposal: quoted), "a proposal that keeps the span passes")
        }
    }

    func testAnApostropheIsNotAQuotation() {
        XCTAssertNil(MarginTidyGuard.rejection(original: "it's the authors' claim and it's fine", proposal: "the authors' claim and it's fine"))
    }

    func testAStretchLiftedFromThePassageIsRejectedUnlessTheSpeakerSaidIt() {
        let passage = "Before this, the committee reviewed the long awaited findings of the national sleep study in detail. After that."
        let lifted = "I think the committee reviewed the long awaited findings of the national sleep study matters"
        let ownWords = "I think it matters a lot for the whole country and for us all in the end"
        XCTAssertEqual(MarginTidyGuard.rejection(original: ownWords, proposal: lifted, passage: passage), .copiedFromPassage)
        XCTAssertNil(MarginTidyGuard.rejection(original: lifted, proposal: lifted, passage: passage), "the speaker said it themselves")
        XCTAssertNil(MarginTidyGuard.rejection(original: ownWords, proposal: "I think it matters a lot for the whole country and for us all", passage: passage))
        XCTAssertNil(MarginTidyGuard.rejection(original: ownWords, proposal: lifted, passage: ""), "no passage, no check")
        // Taking "uh" out joins words into a run the transcript did not have; that is still the speaker's own run.
        let spoken = "I think the committee reviewed uh the long awaited findings of the national sleep study matters"
        XCTAssertNil(MarginTidyGuard.rejection(original: spoken, proposal: lifted, passage: passage))
    }

    func testARunOfSevenFromThePassageIsFine() {
        let passage = "the committee reviewed the long awaited findings of it"
        let proposal = "I think it matters for the committee reviewed the long awaited findings"
        XCTAssertNotEqual(MarginTidyGuard.rejection(original: "I think it matters for the study findings of it", proposal: proposal, passage: passage), .copiedFromPassage)
    }

    /// Spelling differences that are not lost meaning must not drop a good rewrite.
    func testSameMeaningInAnotherSpellingPasses() {
        let rows: [(name: String, original: String, proposal: String)] = [
            ("curly apostrophe in a name", "we met O'Brien at the lab on Monday", "we met O’Brien at the lab on Monday"),
            ("curly apostrophe in a contraction", "it wasn't clear to me at all", "it wasn’t clear to me at all"),
            ("possessive name becomes plain", "I read the paper Sarah's group wrote", "I read the paper Sarah wrote"),
            ("plain name becomes possessive", "I asked Sarah about the paper twice", "I asked about Sarah's paper twice"),
            ("hyphenated name keeps a part", "we heard from Jean-Luc yesterday", "we heard from Jean yesterday"),
            ("hyphenated number words", "it was twenty-five percent higher", "it was twenty-five percent higher"),
            ("hyphenated number split", "it was twenty-five percent higher", "it was twenty five percent higher"),
            ("quoted span ends with a comma", "he said \"no way,\" and left the room", "he said \"no way\" and left the room"),
            ("quoted span moves its full stop", "he said \"no way.\" Then he left", "he said \"no way\". Then he left"),
            ("digits rewritten as words", "she told us at the time it was 12 percent and not 200", "she told us it was twelve percent and not two hundred"),
            ("number words rewritten as digits (Apple's model does this)", "the sample was only forty two people", "The sample was only 42 people."),
            ("thousands as digits", "now it's under two thousand", "Now it is under 2,000."),
            ("percent as a sign", "it fell by twelve percent", "It fell by 12%."),
            ("a title written short", "the doctor said it was fine to stop", "The Dr said it was fine to stop."),
            ("one as a pronoun", "I liked the one by the river better", "I liked the one by the river better."),
            ("a negation said twice tidied to one", "it's not, it's not the whole story", "It's not the whole story."),
            ("spanish stays spanish", "eh, esto no es lo que dijo el autor", "Esto no es lo que dijo el autor."),
            ("contractions expanded", "I can't say it's what they're after, we've seen it", "I cannot say it is what they are after, we have seen it"),
        ]
        for row in rows {
            XCTAssertNil(MarginTidyGuard.rejection(original: row.original, proposal: row.proposal), row.name)
        }
    }

    func testRealLossesAreStillCaughtInAnotherSpelling() {
        XCTAssertEqual(MarginTidyGuard.rejection(original: "it was twenty-five percent higher", proposal: "it was twenty percent higher"), .numberMissing("twenty five"))
        XCTAssertEqual(MarginTidyGuard.rejection(original: "it was twenty-five percent higher", proposal: "it was a lot higher"), .numberMissing("twenty five"))
        XCTAssertEqual(MarginTidyGuard.rejection(original: "I read Sarah's paper twice", proposal: "I read the paper twice"), .nameMissing("Sarah's"))
        XCTAssertEqual(MarginTidyGuard.rejection(original: "we heard from Jean-Luc yesterday", proposal: "we heard from him yesterday"), .nameMissing("Jean-Luc"))
        XCTAssertNotNil(MarginTidyGuard.rejection(original: "he said \"no way,\" and left the room", proposal: "he said \"no chance\" and left the room"))
    }

    func testRewritesTheAppleModelWasSeenMakingAreRejected() {
        // Names from the passage, a translation, and a dropped "nobody" (#4339 eval, 2026-11-24).
        XCTAssertEqual(MarginTidyGuard.rejection(original: "um I think he was wrong about this", proposal: "I think Colonel Varga was wrong about this."), .nameAdded("Colonel"))
        XCTAssertEqual(MarginTidyGuard.rejection(original: "eh, esto no es lo que dijo el autor", proposal: "This is not what the author said."), .languageChanged)
        XCTAssertEqual(MarginTidyGuard.rejection(original: "so nobody checked the numbers here", proposal: "So everyone checked the numbers here."), .negationDropped)
        XCTAssertEqual(MarginTidyGuard.rejection(original: "it's not, it's not, it's not the whole story", proposal: "It's the whole story."), .negationDropped)
        XCTAssertEqual(MarginTidyGuard.rejection(original: "the doctor said it was fine to stop", proposal: "The Dr Smith said it was fine to stop."), .nameAdded("Smith"))
    }
}
