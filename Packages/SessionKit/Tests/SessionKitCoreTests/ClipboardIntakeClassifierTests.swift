import XCTest
@testable import SessionKit

/// #145: Paste & go decides from the clipboard alone whether to add a link or text, or nothing.
final class ClipboardIntakeClassifierTests: XCTestCase {
    private func link(_ string: String) -> ClipboardIntake { .link(URL(string: string)!) }

    func testABareHTTPSLinkIsALink() {
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000671234567"),
            link("https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000671234567")
        )
        XCTAssertEqual(ClipboardIntakeClassifier.classify("http://example.com/feed.xml"), link("http://example.com/feed.xml"))
    }

    func testSurroundingWhitespaceAndNewlinesAreIgnored() {
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("  \n\thttps://www.noahpinion.blog/p/the-poverty-of-anti-tech-thought \n\n"),
            link("https://www.noahpinion.blog/p/the-poverty-of-anti-tech-thought")
        )
    }

    func testALinkWrappedInPunctuationOrBracketsIsStillTheLink() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify("<https://example.com/post>"), link("https://example.com/post"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("\"https://example.com/post\"."), link("https://example.com/post"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("(https://example.com/post)"), link("https://example.com/post"))
    }

    func testALinkThatEndsInItsOwnBracketKeepsIt() {
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("https://en.wikipedia.org/wiki/Mercury_(planet)"),
            link("https://en.wikipedia.org/wiki/Mercury_(planet)")
        )
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("See (https://en.wikipedia.org/wiki/Mercury_(planet))."),
            link("https://en.wikipedia.org/wiki/Mercury_(planet)")
        )
    }

    func testAFileOrProductNameAloneIsTextNotASite() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify("notes.txt"), .text(title: "notes.txt", body: "notes.txt"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("Node.js"), .text(title: "Node.js", body: "Node.js"))
    }

    func testAShareSheetLineWithATitleAndOneLinkIsTheLink() {
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("Listen to this episode: https://overcast.fm/+AbCdEf"),
            link("https://overcast.fm/+AbCdEf")
        )
    }

    func testABareDomainBecomesAnHTTPSLink() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify("example.com/p/a-post"), link("https://example.com/p/a-post"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("astralcodexten.com"), link("https://astralcodexten.com"))
    }

    func testPodcastSubscriptionSchemesBecomeHTTPSLinks() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify("itpc://feeds.example.com/show.rss"), link("https://feeds.example.com/show.rss"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("feed:https://feeds.example.com/show.rss"), link("https://feeds.example.com/show.rss"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("podcast://feeds.example.com/show.rss"), link("https://feeds.example.com/show.rss"))
    }

    func testMultiParagraphTextIsTextTitledByItsFirstWords() {
        let pasted = """

        The poverty of anti-tech thought, and why it keeps coming back

        Critics of technology tend to repeat themselves. See https://example.com/one and https://example.com/two.

        A second paragraph.
        """
        guard case .text(let title, let body) = ClipboardIntakeClassifier.classify(pasted) else {
            return XCTFail("multi-paragraph text should be text")
        }
        XCTAssertEqual(title, "The poverty of anti-tech thought, and why it")
        XCTAssertEqual(body, pasted.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testTextThatMentionsALinkInsideSeveralLinesStaysText() {
        guard case .text = ClipboardIntakeClassifier.classify("First line\nhttps://example.com/post") else {
            return XCTFail("a link inside several lines of text is part of the text")
        }
    }

    func testASingleLineWithTwoLinksIsText() {
        guard case .text = ClipboardIntakeClassifier.classify("Compare https://example.com/a with https://example.com/b") else {
            return XCTFail("two links on one line are ambiguous, so the line is text")
        }
    }

    func testAMarkdownHeadingGivesTheTitleWithoutItsMarks() {
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify("## Notes on listening\n\nBody text."),
            .text(title: "Notes on listening", body: "## Notes on listening\n\nBody text.")
        )
    }

    func testPlainWordsThatLookLikeSchemesOrAbbreviationsStayText() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify("Note: listen again"), .text(title: "Note: listen again", body: "Note: listen again"))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("e.g."), .text(title: "e.g.", body: "e.g."))
        XCTAssertEqual(ClipboardIntakeClassifier.classify("10:30"), .text(title: "10:30", body: "10:30"))
    }

    func testEmptyOrWhitespaceIsUnusable() {
        XCTAssertEqual(ClipboardIntakeClassifier.classify(nil), .unusable(.empty))
        XCTAssertEqual(ClipboardIntakeClassifier.classify(""), .unusable(.empty))
        XCTAssertEqual(ClipboardIntakeClassifier.classify(" \n\t \n"), .unusable(.empty))
    }

    func testANonWebLinkIsUnusableAndSaysWhy() {
        let intake = ClipboardIntakeClassifier.classify("file:///private/var/mobile/notes.txt")
        XCTAssertEqual(intake, .unusable(.unsupportedLink(scheme: "file")))
        XCTAssertEqual(
            ClipboardIntakeUnusableReason.unsupportedLink(scheme: "file").message,
            "Spoken Margins can't open file: links. Copy a web link (https) or some text instead."
        )
    }

    func testOpenInSafariOfferNamesTheReasonAndTheShareBackStep() {
        let offer = OpenInSafariOffer(
            url: URL(string: "https://example.com/paywalled")!,
            reason: OpenInSafariOffer.reason(forHTTPStatus: 403)
        )
        XCTAssertEqual(offer.message, "Spoken Margins couldn't read this page: the site asked for a sign-in or refused the request (HTTP 403).")
        XCTAssertEqual(OpenInSafariOffer.shareBackHint, "Then tap Share › Spoken Margins.")
        XCTAssertEqual(OpenInSafariOffer.reason(forHTTPStatus: 404), "the page wasn't found (HTTP 404).")
    }
}
