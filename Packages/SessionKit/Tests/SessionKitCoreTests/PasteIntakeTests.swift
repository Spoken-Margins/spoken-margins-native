import XCTest
@testable import SessionKit

/// #3782: every place a link can be pasted knows a friend's share link, so it opens as a tapped one does and is never
/// imported as a web page.
final class PasteIntakeTests: XCTestCase {
    private let id = String(repeating: "ab12", count: 8)
    private var key: String { ShareLinkSealing.Key.random().fragment }
    private var host: String { ShareLinkURL.shareHosts[0] }

    private func shareLink(_ pasted: String, opens expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(PasteIntake.classify(pasted), .shareLink(URL(string: expected)!), pasted, file: file, line: line)
    }

    private func notShareLink(_ pasted: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .intake = PasteIntake.classify(pasted) else {
            return XCTFail("a share link was found in: \(pasted)", file: file, line: line)
        }
    }

    // MARK: The table, each row to exactly one route

    func testALinkWithItsKeyIsAShareLink() {
        let link = "https://\(host)/l/\(id)#\(key)"
        shareLink(link, opens: link)
    }

    func testALinkWithoutAKeyOrWithAnIdCutShortIsStillAShareLink() {
        for link in ["https://\(host)/l/\(id)", "https://\(host)/l/\(id)#", "https://\(host)/l/\(id.prefix(12))",
                     "https://\(host)/l/\(id.prefix(12))#\(key)", "https://\(host)/l/"] {
            shareLink(link, opens: link) // opening it says it isn't a share link; it is never imported as a web page
        }
    }

    func testALinkStuckToBracketsOrASchemeOpenerIsStillTheShareLink() {
        let link = "https://\(host)/l/\(id)#\(key)"
        for text in ["[Hear it](\(link))", "see [Hear it](\(link)).", "<\(link)>", "feed:\(link)", "(\"\(link)\")"] {
            shareLink(text, opens: link)
        }
    }

    func testALinkInsideAnotherSitesQueryIsNotAShareLink() {
        let link = "https://\(host)/l/\(id)#\(key)"
        for text in ["other.com?u=\(link)", "https://other.com/go?u=\(link)", "other.com/x=\(link)"] {
            XCTAssertNil(PastedShareLink.first(in: text), text)
        }
    }

    func testEveryShareHostAndTheProductionHostIsAShareHost() {
        for name in Set(ShareLinkURL.shareHosts + [ProductServer.productionHost]) {
            let link = "https://\(name)/l/\(id)#\(key)"
            shareLink(link, opens: link)
        }
    }

    func testSpacesAndLineBreaksAroundTheLinkAreIgnored() {
        let link = "https://\(host)/l/\(id)#\(key)"
        shareLink("\(link) ", opens: link)
        shareLink("  \(link)\n", opens: link)
        shareLink("\n\n\(link)\r\n", opens: link)
    }

    func testALinkInsideTheWholeMessageAFriendSentIsFound() {
        let link = "https://\(host)/l/\(id)#\(key)"
        let message = """
        Cole sent you 3 Margins on "A very long title that goes on and on for far more than the one-line limit \
        of the classifier because friends write long messages and the sender added their own words as well, \
        and more words, so the whole message is longer than 280 characters in total for sure".

        Hear them here: \(link)
        Don't have the app yet? Get it at https://\(host)/join
        """
        XCTAssertGreaterThan(message.count, ClipboardIntakeClassifier.shortLinkLineLimit)
        shareLink(message, opens: link)
    }

    func testTheFirstShareLinkInTheTextWins() {
        let first = "https://\(host)/l/\(id)#\(key)"
        let second = "https://\(host)/l/\(String(repeating: "cd34", count: 8))#\(key)"
        shareLink("\(first) and \(second)", opens: first)
    }

    func testHTTPOnAShareHostAndAMissingSchemeOpenAsHTTPS() {
        let tail = "\(host)/l/\(id)#\(key)"
        shareLink("http://\(tail)", opens: "https://\(tail)")
        shareLink("\(tail)", opens: "https://\(tail)")
    }

    func testAnUppercaseHostIsAShareLink() {
        let link = "https://\(host.uppercased())/l/\(id)#\(key)"
        shareLink(link, opens: link)
    }

    func testPunctuationAroundALinkInProseIsNotPartOfIt() {
        let link = "https://\(host)/l/\(id)#\(key)"
        for pasted in ["\(link).", "\(link))", "(\(link))", "“\(link)”", "\(link),", "\(link)!", "\(link)?", "<\(link)>", "\"\(link)\"", "[\(link)]"] {
            shareLink(pasted, opens: link)
        }
    }

    // MARK: What stays an ordinary link

    func testOtherPagesOnTheShareHostAndOtherHostsAreOrdinaryLinks() {
        let joined = "https://\(host)/join"
        XCTAssertEqual(PasteIntake.classify(joined), .intake(.link(URL(string: joined)!)))
        for pasted in [
            "https://\(host)/l", "https://\(host)/about", "https://\(host)/", "https://www.\(host)/l/\(id)#\(key)",
            "https://example.com/l/\(id)#\(key)", "https://example.com/post", "https://podcasts.apple.com/us/podcast/the-daily/id1200361736",
            "https://\(host).example.com/l/\(id)", "https://evil.com/\(host)/l/\(id)", "https://user@\(host)/l/\(id)",
            "ftp://\(host)/l/\(id)", "spokenmargins://\(host)/l/\(id)",
        ] {
            notShareLink(pasted)
        }
    }

    func testTextAndEmptyAreNotShareLinks() {
        for pasted in ["", "   \n", "The l/ key is ready", "see /l/abc", "spokenmargins.com is where it lives", "notes.txt"] {
            notShareLink(pasted)
        }
        XCTAssertEqual(PasteIntake.classify(nil), .intake(.unusable(.empty)))
    }

    func testEverythingThatIsNotAShareLinkClassifiesAsItDidBefore() {
        for pasted in ["https://example.com/post", "Listen to this: https://overcast.fm/+AbCdEf", "just some words", "file:///tmp/a.txt", ""] {
            XCTAssertEqual(PasteIntake.classify(pasted), .intake(ClipboardIntakeClassifier.classify(pasted)), pasted)
        }
    }

    // MARK: The Library's copied-link card

    func testThePasteButtonOnTheCopiedLinkCardTakesAShareLink() {
        let link = "https://\(host)/l/\(id)#\(key)"
        XCTAssertEqual(ClipboardLinkOffer.pasteResult(for: link), .link(URL(string: link)!))
        XCTAssertEqual(ClipboardLinkOffer.pasteResult(for: "Hear it: \(link)"), .link(URL(string: link)!))
        XCTAssertEqual(ClipboardLinkOffer.pasteResult(for: "https://example.com/post"), .link(URL(string: "https://example.com/post")!))
        XCTAssertEqual(ClipboardLinkOffer.pasteResult(for: "some words"), .notALink)
    }
}
