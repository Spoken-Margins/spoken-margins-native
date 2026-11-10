import Foundation
import XCTest
@testable import SessionKit

/// An article shared from Safari (Forethought, "Hard cases for AI behavioural design") was read with
/// every link's address: its table of contents and cross-references link inside the page,
/// `[Executive summary](#executive-summary)`, and only addresses that look like a web address
/// (`https://`, `www.`, or a dot) were dropped. A link's words are read; its address never is.
final class InPageLinkSpeechTests: XCTestCase {
    func testLinksInsideThePageReadOnlyTheirWords() {
        let rows: [(String, String)] = [
            ("[Executive summary](#executive-summary)", "Executive summary"),
            ("see [here](#11-legal-orders-vs-significant-harm).", "see here."),
            ("[Appendix 1c](#1c-legal-orders-vs-international-balance-of-power) describes", "Appendix 1c describes"),
            ("[Top](#)", "Top"),
            ("[Top](#Top)", "Top"),
            ("[Café](#café)", "Café"),
            ("[Note](#note \"Note\")", "Note"),
            ("[Docs](/docs/intro) now", "Docs now"),
            ("[Next](./next) now", "Next now"),
            ("[Up](../index) now", "Up now"),
            ("[Write to us](mailto:a@b.co)", "Write to us"),
            ("[Call](tel:+15551234) us", "Call us"),
            ("[Mixed](HTTPS://Example.com) case", "Mixed case"),
        ]
        for (input, expected) in rows {
            XCTAssertEqual(SpeechTextNormalizer.normalize(input), expected, input)
            XCTAssertEqual(SpeechTextNormalizer.normalizeImportedText(input), expected, input)
        }
    }

    func testBracketsThatAreNotLinksStayAsWritten() {
        for text in ["Footnote [1](2) stays.", "Pair [a](b) stays.", "Set [x](y z) stays."] {
            XCTAssertEqual(SpeechTextNormalizer.removingLinkTitleRemnants(from: text), text)
            XCTAssertTrue(SpeechTextNormalizer.normalizeImportedText(text).contains("("), text)
        }
    }

    func testSharedTableOfContentsImportsWithoutAddresses() throws {
        let markdown = """
        [Executive summary](#executive-summary)

        [I. AI is radically different from previous tools](#i-ai-is-radically-different-from-previous-tools)

        The paper explores other scenarios ([here](#11-legal-orders-vs-significant-harm) and [here](#12-legal-orders-vs-international-balance-of-power)).
        """
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Hard cases", contents: markdown)
        XCTAssertFalse(parsed.text.contains("#"), parsed.text)
        XCTAssertFalse(parsed.text.contains("]("), parsed.text)
        XCTAssertTrue(parsed.text.contains("The paper explores other scenarios (here and here)."), parsed.text)
    }
}
