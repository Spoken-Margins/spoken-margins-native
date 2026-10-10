import Foundation
import SessionKit
import SessionKitSharing
import XCTest

/// Where a shared article Margin lands in the recipient's copy: the exact offsets, not only the evidence class
/// (PKT-05 of the #1039 audit). The tests in SharingTests.testArticleResolverDistinguishesWrongAmbiguousAndVerified
/// check `.status` and `.evidenceClass`, which a resolver that puts the Margin at the end of the quote, or never
/// uses the sender's surrounding words, still satisfies.
final class PortableArticleAnchorResolverTests: XCTestCase {
    private let quote = "The durable idea that prompted this note."

    private func anchor(
        quote: String? = "The durable idea that prompted this note.",
        prefix: String? = nil, suffix: String? = nil, start: Int? = nil, end: Int? = nil
    ) -> PortableAnchorEvidence {
        PortableAnchorEvidence(
            anchorType: .text, startChar: start, endChar: end, exactText: quote, prefix: prefix, suffix: suffix
        )
    }

    private func resolve(
        _ anchor: PortableAnchorEvidence, in text: String, editionOf edition: String? = nil
    ) -> ImportedAnchorResolution {
        PortableArticleAnchorResolver.resolve(
            anchor: anchor, in: text,
            expectedExactEditionSHA256: edition.map(PortableArticleAnchorResolver.exactEditionSHA256)
        )
    }

    /// The characters a resolution covers, read back out of the text. A wrong start or end shows up as the wrong words.
    private func covered(_ resolution: ImportedAnchorResolution, in text: String) -> String? {
        guard let start = resolution.localStartChar, let end = resolution.localEndChar else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    func testAUniqueQuoteLandsOnItsOwnCharacters() {
        let text = "Before this passage. The durable idea that prompted this note. After this passage."
        let resolution = resolve(anchor(), in: text)
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(resolution.localStartChar, 21)
        XCTAssertEqual(resolution.localEndChar, 62)
        XCTAssertEqual(covered(resolution, in: text), quote)
        XCTAssertEqual(resolution.confidence, 0.98)
        XCTAssertFalse(resolution.isAmbiguous)
    }

    func testOffsetsCountCharactersNotUTF8BytesOrScalars() {
        // An emoji with a skin tone is one Character but several scalars and many bytes; offsets are Characters,
        // which is what the sender's `startChar`/`endChar` count.
        let text = "Café 👍🏽 notes. \(quote) Ça finit."
        let resolution = resolve(anchor(), in: text)
        XCTAssertEqual(resolution.localStartChar, "Café 👍🏽 notes. ".count)
        XCTAssertEqual(covered(resolution, in: text), quote)
    }

    // MARK: The sender's surrounding words pick the right copy of a repeated quote

    private var repeated: String {
        "Alpha opening line. \(quote) Alpha closing line. Beta opening line. \(quote) Beta closing line."
    }
    private var firstCopyStart: Int { "Alpha opening line. ".count }
    private var secondCopyStart: Int { "Alpha opening line. \(quote) Alpha closing line. Beta opening line. ".count }

    func testAQuoteThatAppearsTwiceLandsWhereTheSendersWordsBeforeAndAfterPointSecondCopy() {
        let resolution = resolve(anchor(prefix: "Beta opening line.", suffix: "Beta closing line."), in: repeated)
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(resolution.localStartChar, secondCopyStart)
        XCTAssertEqual(resolution.localEndChar, secondCopyStart + quote.count)
        XCTAssertEqual(resolution.confidence, 0.92)
        XCTAssertFalse(resolution.isAmbiguous)
    }

    func testTheSameRuleSelectsTheFirstCopyWhenTheContextIsTheFirstCopys() {
        // Not "always the last copy": the same text with the other context lands on the other copy.
        let resolution = resolve(anchor(prefix: "Alpha opening line.", suffix: "Alpha closing line."), in: repeated)
        XCTAssertEqual(resolution.localStartChar, firstCopyStart)
        XCTAssertEqual(resolution.localEndChar, firstCopyStart + quote.count)
    }

    func testTheWordsBeforeAloneAndTheWordsAfterAloneEachSelectTheirCopy() {
        // The sender's context is the characters right around the quote, spaces included.
        let before = resolve(anchor(prefix: "Beta opening line. "), in: repeated)
        XCTAssertEqual(before.localStartChar, secondCopyStart, "the words before the quote pick the copy")
        let after = resolve(anchor(suffix: " Beta closing line."), in: repeated)
        XCTAssertEqual(after.localStartChar, secondCopyStart, "the words after the quote pick the copy")
        // Each side is read from its own side of the quote: the prefix of the first copy is not its suffix.
        let beforeFirst = resolve(anchor(prefix: "Alpha opening line. "), in: repeated)
        XCTAssertEqual(beforeFirst.localStartChar, firstCopyStart)
        let afterFirst = resolve(anchor(suffix: " Alpha closing line."), in: repeated)
        XCTAssertEqual(afterFirst.localStartChar, firstCopyStart)
    }

    func testContextThatFitsBothCopiesEquallyIsAmbiguousNotAGuess() {
        let twin = "Same opening. \(quote) Same closing. Same opening. \(quote) Same closing."
        let resolution = resolve(anchor(prefix: "Same opening.", suffix: "Same closing."), in: twin)
        XCTAssertEqual(resolution.evidenceClass, .ambiguous)
        XCTAssertTrue(resolution.isAmbiguous)
        XCTAssertNil(resolution.localStartChar)
        XCTAssertNil(resolution.localEndChar)
        let noContext = resolve(anchor(), in: repeated)
        XCTAssertEqual(noContext.evidenceClass, .ambiguous)
        XCTAssertNil(noContext.localStartChar)
    }

    // MARK: The recipient's copy is typeset differently

    func testATypographicQuoteInTheRecipientsCopyStillLandsOnTheWholeQuote() {
        let text = "He said: “don’t panic” and left."
        let resolution = resolve(anchor(quote: "don't panic"), in: text)
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(covered(resolution, in: text), "don’t panic")
        XCTAssertEqual(resolution.localStartChar, 10)
        XCTAssertEqual(resolution.localEndChar, 21)
        XCTAssertEqual(resolution.confidence, 0.88, "a typography-only match is less certain than a verbatim one")
    }

    func testDifferentWhitespaceAndCaseInTheRecipientsCopyStillLand() {
        let text = "Intro.\n\nthe   DURABLE idea\nthat prompted this note! Outro."
        let resolution = resolve(anchor(), in: text)
        XCTAssertEqual(covered(resolution, in: text), "the   DURABLE idea\nthat prompted this note")
        XCTAssertEqual(resolution.confidence, 0.88)
    }

    func testARepeatedTypographicQuoteIsAlsoPickedByContext() {
        let text = "Alpha opening line. “Don’t panic” Alpha closing line. Beta opening line. “Don’t panic” Beta closing line."
        let resolution = resolve(
            anchor(quote: "Don't panic", prefix: "Beta opening line. “", suffix: "” Beta closing line."), in: text
        )
        XCTAssertEqual(resolution.localStartChar, "Alpha opening line. “Don’t panic” Alpha closing line. Beta opening line. “".count)
        XCTAssertEqual(resolution.confidence, 0.84)
    }

    // MARK: The exact edition: the sender's offsets are used, and only when they still say the same words

    func testTheSameEditionUsesTheSendersOffsetsEvenForARepeatedQuote() {
        let start = secondCopyStart
        let resolution = resolve(
            anchor(start: start, end: start + quote.count), in: repeated, editionOf: repeated
        )
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(resolution.localStartChar, start)
        XCTAssertEqual(resolution.localEndChar, start + quote.count)
        XCTAssertEqual(resolution.confidence, 1, "the identical edition is the only certain placement")
    }

    func testOffsetsThatNoLongerSayTheSameWordsAreNotUsed() {
        // The recipient's text hashes as the same edition, but the characters at the sender's offsets are other words
        // (a corrupted offset). The resolver must fall back to finding the quote, not trust the numbers.
        let text = "Before this passage. \(quote) After this passage."
        let resolution = resolve(anchor(start: 0, end: quote.count), in: text, editionOf: text)
        XCTAssertEqual(covered(resolution, in: text), quote)
        XCTAssertEqual(resolution.localStartChar, 21)
        XCTAssertEqual(resolution.confidence, 0.98, "found by search, not by the sender's offsets")
    }

    func testADifferentEditionIgnoresTheSendersOffsetsAndSearches() {
        let senders = "\(quote) Tail."
        let recipients = "A new first paragraph was added. \(senders)"
        let resolution = resolve(anchor(start: 0, end: quote.count), in: recipients, editionOf: senders)
        XCTAssertEqual(resolution.localStartChar, "A new first paragraph was added. ".count)
        XCTAssertEqual(resolution.confidence, 0.98)
    }

    // MARK: Nothing to place

    func testAQuoteThatIsNotInTheRecipientsCopyIsUnresolvedWithNoOffsets() {
        let resolution = resolve(anchor(), in: "A completely different article.")
        XCTAssertEqual(resolution.evidenceClass, .unresolved)
        XCTAssertNil(resolution.localStartChar)
        XCTAssertNil(resolution.localEndChar)
        XCTAssertFalse(resolution.isAmbiguous)
    }

    func testAnAnchorWithoutAQuoteIsUnresolved() {
        for missing in [nil, "", "   \n"] as [String?] {
            let resolution = resolve(anchor(quote: missing), in: "Some text.")
            XCTAssertEqual(resolution.evidenceClass, .unresolved, "quote \(String(describing: missing))")
            XCTAssertNil(resolution.localStartChar)
        }
    }
}
