import XCTest
@testable import SessionKit

/// One cap rule for the source text around a shared Margin (#2237, D16): 120 characters after, and before scaled to
/// three times the comment, 280 at least. Builds 32 and 34 reject packet context over 500, so 500 is the ceiling
/// until they are retired.
final class ExcerptCapRuleTests: XCTestCase {
    private let words = String(repeating: "alpha beta gamma ", count: 80)

    func testBeforeCapScalesWithTheCommentBetweenItsFloorAndItsCeiling() {
        let rows: [(comment: Int, cap: Int)] = [
            (0, 280), (1, 280), (93, 280), (94, 282), (100, 300), (166, 498), (167, 500), (400, 500), (10_000, 500)
        ]
        for row in rows {
            XCTAssertEqual(ExcerptCapRule.beforeCap(commentLength: row.comment), row.cap, "comment of \(row.comment)")
        }
        XCTAssertEqual(ExcerptCapRule.beforeCap(commentLength: -5), 280)
    }

    func testTheBeforeCeilingNeverPassesWhatShippedBuildsAccept() {
        XCTAssertLessThanOrEqual(ExcerptCapRule.beforeMaximum, BoundedAnchorContext.maximumCharactersPerSide)
        XCTAssertLessThanOrEqual(ExcerptCapRule.beforeMaximum, ExcerptCapRule.beforeScaleMaximum)
        XCTAssertEqual(ExcerptCapRule.afterMaximum, 120)
    }

    func testCommentLengthIsTheTranscriptElseAboutFifteenCharactersASecond() {
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: "  Keep going.  "), 11)
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: "e\u{301}👩🏽‍💻"), 2, "grapheme clusters, not scalars")
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: nil, recordingSeconds: 10), 150)
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: " \n ", recordingSeconds: 4), 60, "a blank transcript counts as none")
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: "Words", recordingSeconds: 60), 5, "the transcript wins")
        for seconds in [0.0, -3.0, .nan, .infinity] {
            XCTAssertEqual(ExcerptCapRule.commentLength(transcript: nil, recordingSeconds: seconds), 0)
        }
        XCTAssertEqual(ExcerptCapRule.commentLength(transcript: nil), 0)
    }

    func testShortContextIsKeptWhole() {
        let context = ExcerptCapRule.select(before: " \n café\t ", after: "Right  after", commentLength: 20)
        XCTAssertEqual(context.before, "café")
        XCTAssertEqual(context.after, "Right after")
        XCTAssertEqual(ExcerptCapRule.select(before: "", after: "", commentLength: 0), BoundedAnchorContext(before: "", after: ""))
    }

    func testLongContextIsCutAtWordBoundariesNearTheMargin() {
        let context = ExcerptCapRule.select(before: words, after: words, commentLength: 20)
        XCTAssertLessThanOrEqual(context.before.count, 280)
        XCTAssertLessThanOrEqual(context.after.count, 120)
        XCTAssertGreaterThan(context.before.count, 260, "keeps as much as fits")
        XCTAssertGreaterThan(context.after.count, 100)
        let normalized = BoundedAnchorContext.normalizedWhitespace(words)
        XCTAssertTrue(normalized.hasSuffix(context.before), "before ends where the Margin starts")
        XCTAssertTrue(normalized.hasPrefix(context.after), "after starts where the Margin ends")
        let vocabulary: Set<String> = ["alpha", "beta", "gamma"]
        XCTAssertTrue(Set(context.before.split(separator: " ").map(String.init)).isSubset(of: vocabulary), "no half words before")
        XCTAssertTrue(Set(context.after.split(separator: " ").map(String.init)).isSubset(of: vocabulary), "no half words after")
    }

    func testBeforeGrowsWithALongerComment() {
        let short = ExcerptCapRule.select(before: words, after: "", commentLength: 20).before
        let long = ExcerptCapRule.select(before: words, after: "", commentLength: 150).before
        XCTAssertGreaterThan(long.count, short.count)
        XCTAssertLessThanOrEqual(long.count, 450)
    }

    func testOneLongWordIsCutHardRatherThanDropped() {
        let word = String(repeating: "x", count: 600)
        let context = ExcerptCapRule.select(before: word, after: word, commentLength: 5)
        XCTAssertEqual(context.before.count, 280)
        XCTAssertEqual(context.after.count, 120)
    }

    func testAnExactFitIsNotTrimmed() {
        let exactAfter = String(repeating: "y", count: 120)
        XCTAssertEqual(ExcerptCapRule.select(before: "", after: exactAfter, commentLength: 5).after, exactAfter)
        let exactBefore = String(repeating: "y", count: 280)
        XCTAssertEqual(ExcerptCapRule.select(before: exactBefore, after: "", commentLength: 5).before, exactBefore)
        let head = "one " + String(repeating: "y", count: 116)   // exactly 120 characters
        XCTAssertEqual(ExcerptCapRule.select(before: "", after: head + " tail", commentLength: 5).after, head,
                       "a cut that lands on a space keeps the word before it")
        let midWord = "one " + String(repeating: "y", count: 117)
        XCTAssertEqual(ExcerptCapRule.select(before: "", after: midWord, commentLength: 5).after, "one",
                       "a cut inside a word drops that word's partial end")
    }

    func testEmojiAndCombiningCharactersCountAsCharactersAndNeverPassTheCapInScalars() {
        let cluster = "e\u{301}👩🏽‍💻"   // two characters, six scalars
        let text = String(repeating: cluster, count: 400)
        let context = ExcerptCapRule.select(before: text, after: text, commentLength: 5)
        XCTAssertLessThanOrEqual(context.before.count, 280)
        XCTAssertLessThanOrEqual(context.before.unicodeScalars.count, 280, "a server counting code points agrees")
        XCTAssertLessThanOrEqual(context.after.count, 120)
        XCTAssertLessThanOrEqual(context.after.unicodeScalars.count, 120)
        XCTAssertFalse(context.before.isEmpty)
        XCTAssertTrue(text.hasSuffix(context.before), "cut on a character boundary, never inside a cluster")
        XCTAssertTrue(text.hasPrefix(context.after))
    }

    func testAMarginAtTheVeryStartOrEndOfTheSourceHasOneSideOnly() {
        let atStart = ExcerptCapRule.select(before: "", after: words, commentLength: 30)
        XCTAssertTrue(atStart.before.isEmpty)
        XCTAssertFalse(atStart.after.isEmpty)
        let atEnd = ExcerptCapRule.select(before: words, after: "  \n", commentLength: 30)
        XCTAssertFalse(atEnd.before.isEmpty)
        XCTAssertTrue(atEnd.after.isEmpty)
    }

    func testAMarginsPacketKeepsItsOldBoundWhenNoCommentLengthIsGiven() {
        let long = String(repeating: "z", count: 700)
        let evidence = PortableAnchorEvidence(anchorType: .text, startChar: 0, endChar: 0, prefix: long, suffix: long).bounded()
        XCTAssertEqual(evidence.prefix?.count, 500, "Listening Maps and old callers are not changed")
        XCTAssertEqual(evidence.suffix?.count, 500)
    }
}
