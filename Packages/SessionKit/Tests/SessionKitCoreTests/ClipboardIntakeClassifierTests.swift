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

    /// A note around one link is part of the share while it is short: 280 characters at most, not counting the link, so a
    /// long tracking link is no reason to import the message as text (#4809). A longer note is pasted text. A bare link
    /// has no limit.
    func testANoteAroundALinkIsTheLinkUpTo280CharactersOfNoteAndTextBeyond() {
        let address = "https://example.com/" + String(repeating: "a", count: 400)
        for noteLength in [16, 279, 280] {
            let note = String(repeating: "n", count: noteLength - 1) + " "
            XCTAssertEqual(ClipboardIntakeClassifier.classify(note + address), link(address), "\(noteLength) characters of note")
            XCTAssertEqual(ClipboardIntakeClassifier.classify(address + " " + note.dropLast()), link(address), "link first, \(noteLength)")
        }
        let long = String(repeating: "n", count: 280) + " " + address
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify(long),
            .text(title: ClipboardIntakeClassifier.title(for: long), body: long),
            "281 characters of note is text"
        )

        let bareLong = "https://example.com/" + String(repeating: "a", count: 400)
        XCTAssertEqual(ClipboardIntakeClassifier.classify(bareLong), link(bareLong), "a bare link is a link whatever its length")
    }

    /// #4809: apps copy "Title" then the link on the next line, or a note, a blank line and the link. These are the link.
    func testATitleAndALinkOnSeparateLinesIsTheLink() {
        let address = "https://example.com/post"
        let cases = [
            "First line\n\(address)",
            "First line\r\n\(address)",
            "\(address)\nFirst line",
            "Check this out\n\n\(address)\n",
            "  Check this out \(address) \n",
            "Title — Site\n(\(address))",
            "Listen: [Hear it](\(address))",
            "Look at this: \(address).",
            "\u{201C}\(address)\u{201D} is worth a listen",
        ]
        for pasted in cases {
            XCTAssertEqual(ClipboardIntakeClassifier.classify(pasted), link(address), "\(pasted.debugDescription)")
        }
    }

    /// Still text: two links, a long note around one, no web link, or a link that is not a web link.
    func testNotesThatAreNotAShareStayText() {
        let address = "https://example.com/post"
        let article = String(repeating: "A sentence about things. ", count: 40)
        for pasted in [
            "Compare \(address) with https://example.com/b",
            "\(article)\n\(address)",
            "Check this out example.com or mail me@example.com",
            "Check this out mailto:me@example.com",
            "Check this out ftp://example.com/file",
        ] {
            guard case .text = ClipboardIntakeClassifier.classify(pasted) else {
                XCTFail("should stay text: \(pasted.prefix(60).debugDescription)")
                continue
            }
        }
        XCTAssertGreaterThan(article.count, ClipboardIntakeClassifier.shortNoteLimit)
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

    /// A short run of words with a huge token among them must classify at once: only words that could hold a link are stripped.
    func testAHugeTokenInAShortNoteDoesNotStallTheClassifier() {
        let started = Date()
        for pasted in ["a " + String(repeating: ")", count: 20_000), "see " + String(repeating: "(", count: 20_000) + " x"] {
            guard case .text = ClipboardIntakeClassifier.classify(pasted) else { return XCTFail("should be text") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "was quadratic in the run of brackets")
    }

    func testTwoMarkdownLinksStuckTogetherAreTwoLinksSoText() {
        guard case .text = ClipboardIntakeClassifier.classify("Read [a](https://x.com/a)[b](https://y.com/b)") else {
            return XCTFail("two links in one word are ambiguous")
        }
    }

    func testTextThatMentionsALinkInsideLongProseStaysText() {
        let body = (1...12).map { "Line \($0) of notes about listening, with enough words to be notes." }.joined(separator: "\n")
            + "\nhttps://example.com/post"
        XCTAssertGreaterThan(body.count, ClipboardIntakeClassifier.shortNoteLimit)
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify(body),
            .text(title: "Line 1 of notes about listening, with enough", body: body),
            "a link inside pages of text is part of the text"
        )
    }

    func testASingleLineWithTwoLinksIsText() {
        let line = "Compare https://example.com/a with https://example.com/b"
        XCTAssertEqual(
            ClipboardIntakeClassifier.classify(line),
            .text(title: line, body: line),
            "two links on one line are ambiguous, so the line is text"
        )
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
