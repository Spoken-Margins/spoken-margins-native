import Foundation
import XCTest
@testable import SessionKit

/// #560: a Wikipedia article shared from Safari read every link's title aloud ("of a book book",
/// "doodles, doodle"). Its Markdown links carry titles, `[book](https://… "Book")`, and some URLs
/// hold parentheses, `/wiki/Margin_(typography)`; the import kept the titles and dropped the URLs.
final class LinkTitleSpeechTests: XCTestCase {
    /// The first paragraph of https://en.wikipedia.org/wiki/Marginalia as the Safari extension
    /// hands it over.
    static let marginaliaMarkdown = #"""
    **Marginalia** (or **apostils**) are marks made in the [margins](https://en.wikipedia.org/wiki/Margin_(typography) "Margin (typography)") of a [book](https://en.wikipedia.org/wiki/Book "Book") or other document. They may be scribbles, comments, [glosses (annotations)](https://en.wikipedia.org/wiki/Gloss_(annotation) "Gloss (annotation)"), [critiques](https://en.wikipedia.org/wiki/Critique "Critique"), [doodles](https://en.wikipedia.org/wiki/Doodle "Doodle"), [drolleries](https://en.wikipedia.org/wiki/Drolleries "Drolleries"), or [illuminations](https://en.wikipedia.org/wiki/Illuminated_manuscript "Illuminated manuscript").
    """#

    /// What an import before the fix stored for that paragraph (the Test Desk's segment text).
    static let storedBeforeFix = #"""
    Marginalia (or apostils) are marks made in the margins "Margin (typography)") of a [book]( "Book") or other document. They may be scribbles, comments, glosses (annotations) "Gloss (annotation)"), [critiques]( "Critique"), [doodles]( "Doodle"), [drolleries]( "Drolleries"), or [illuminations]( "Illuminated manuscript").
    """#

    static let asWritten = "Marginalia (or apostils) are marks made in the margins of a book or other document. They may be scribbles, comments, glosses (annotations), critiques, doodles, drolleries, or illuminations."

    /// The stored text as it now reads: every link without a URL loses its title. A title left
    /// after a URL with parentheses (`margins "Margin (typography)")`) reads like a quoted title in
    /// prose, so it stays; sharing the article again gives the clean text.
    static let storedAsNowRead = #"Marginalia (or apostils) are marks made in the margins "Margin (typography)") of a book or other document. They may be scribbles, comments, glosses (annotations) "Gloss (annotation)"), critiques, doodles, drolleries, or illuminations."#

    func testImportedWikipediaLinksKeepTheirTextAndDropTheirTitles() throws {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Marginalia", contents: Self.marginaliaMarkdown)
        XCTAssertEqual(parsed.text, Self.asWritten)
        XCTAssertEqual(SpeechTextNormalizer.normalize(parsed.text), Self.asWritten)
    }

    func testTextStoredByAnEarlierImportIsSpokenWithoutTheTitles() {
        XCTAssertEqual(SpeechTextNormalizer.normalize(Self.storedBeforeFix), Self.storedAsNowRead)
        XCTAssertEqual(SpeechTextNormalizer.projectForSystemSpeech(Self.storedBeforeFix).text, Self.storedAsNowRead)
    }

    func testSpokenOffsetsStillPointIntoTheStoredText() throws {
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(Self.storedBeforeFix)
        let source = Array(Self.storedBeforeFix)
        let spoken = Array(normalized.text)
        let book = Array("of a book or")
        let start = try XCTUnwrap((0...(spoken.count - book.count)).first { Array(spoken[$0..<($0 + book.count)]) == book })
        // "book" in the spoken text maps to "book" inside "[book]( \"Book\")" in the stored text.
        let bookOffset = normalized.sourceOffset(atSpokenCharacterOffset: start + 5)
        XCTAssertEqual(String(source[bookOffset..<(bookOffset + 4)]), "book")
        XCTAssertEqual(source[bookOffset - 1], "[")
    }

    func testOnlyLinkTitleRemnantsAreRemovedForDisplay() {
        XCTAssertEqual(SpeechTextNormalizer.removingLinkTitleRemnants(from: Self.storedBeforeFix), Self.storedAsNowRead)
        let untouched = [
            "See [the paper](https://example.com/paper) for details.",
            "Read https://example.com/x today.",
            "Footnote [1](2) stays.",
            "She wrote (in the margin \"no (never)\") and left.",
            "A quote ends the line \"like this\")",
            "the \"Manual of Style (2nd ed.)\") was revised.",
        ]
        for text in untouched {
            XCTAssertEqual(SpeechTextNormalizer.removingLinkTitleRemnants(from: text), text)
        }
    }

    func testOrdinaryLinksAndProseAreSpokenAsBefore() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("See [the paper](https://example.com/paper) for details."),
                       "See the paper for details.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("See [the post](www.example.com/post 'Post') now."),
                       "See the post now.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("She wrote (in the margin \"no (never)\") and left."),
                       "She wrote (in the margin \"no (never)\") and left.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("They said \"yes\") and went."),
                       "They said \"yes\") and went.")
        // A parenthesis opened on an earlier PDF line or before a resumed chunk (#560 review).
        XCTAssertEqual(SpeechTextNormalizer.normalizeImportedText("the \"Manual of Style (2nd ed.)\") was revised."),
                       "the \"Manual of Style (2nd ed.)\") was revised.")
        // An unbalanced "(" in a URL still ends the link where it always did.
        XCTAssertEqual(SpeechTextNormalizer.normalize("Open [this](https://example.com/a(b) now."), "Open this now.")
    }
}
