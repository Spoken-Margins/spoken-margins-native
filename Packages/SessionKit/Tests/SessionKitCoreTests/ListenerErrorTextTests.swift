import Foundation
import SessionKit
import SessionKitFeeds
import XCTest

/// #1965: failure banners read as one plain line, never a code or a Swift dump.
final class ListenerErrorTextTests: XCTestCase {
    private struct PlainError: LocalizedError {
        var errorDescription: String? { "This PDF is only pictures of pages, so there is no text to read aloud." }
    }

    private struct CaseNameError: LocalizedError {
        var errorDescription: String? { "pdfHasNoExtractableText" }
    }

    private enum PlainEnumError: Error { case pdfHasNoExtractableText }

    func testAnErrorWithAPlainSentenceKeepsIt() {
        XCTAssertEqual(
            ListenerErrorText.message(for: PlainError()),
            "This PDF is only pictures of pages, so there is no text to read aloud.")
        XCTAssertEqual(
            ListenerErrorText.message(for: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file is locked."])),
            "The file is locked.")
    }

    func testACodeBecomesTheGenericLine() {
        XCTAssertEqual(
            ListenerErrorText.message(for: SessionKitError.persistenceFailed("share_curation_interjection_missing")),
            ListenerErrorText.fallback)
        XCTAssertEqual(ListenerErrorText.message(for: SessionKitError.missingFixture("a")), ListenerErrorText.fallback)
    }

    func testASwiftCaseNameOrDumpBecomesTheGenericLine() {
        XCTAssertEqual(ListenerErrorText.message(for: CaseNameError()), ListenerErrorText.fallback)
        XCTAssertEqual(ListenerErrorText.message(for: PlainEnumError.pdfHasNoExtractableText), ListenerErrorText.fallback)
    }

    func testAnNSErrorWithNoDescriptionBecomesTheGenericLine() {
        XCTAssertEqual(ListenerErrorText.message(for: NSError(domain: "SomeDomain", code: 5)), ListenerErrorText.fallback)
        XCTAssertEqual(
            ListenerErrorText.message(for: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: ""])),
            ListenerErrorText.fallback)
    }

    /// Apple's wording is a plain sentence; Linux's is a dump. Either way the listener never reads the dump.
    func testAURLErrorNeverShowsADump() {
        let message = ListenerErrorText.message(for: URLError(.notConnectedToInternet))
        XCTAssertFalse(ListenerErrorText.looksLikeCodeOrDump(message), message)
    }

    func testNeighbouringShapesOfCodeAndDump() {
        let dumps = [
            "", "   ", "pdfHasNoExtractableText", "rss_episode_ambiguous", "persistence_failed:disk is full",
            "tooDeep(depth: 4)", "Foo.Bar.baz(\"x\")", "Optional(\"x\")",
            "Error Domain=NSCocoaErrorDomain Code=264 \"The file couldn’t be opened.\"",
            "The operation couldn’t be completed. (SomeDomain error 5.)",
            "The operation could not be completed. (SomeDomain error -1.)"
        ]
        for text in dumps {
            XCTAssertTrue(ListenerErrorText.looksLikeCodeOrDump(text), "\"\(text)\"")
        }
        let plain = [
            "Enter a valid feed URL.", "The Internet connection appears to be offline.",
            "That link isn't a podcast or news feed. Check the address.", "Couldn’t read this file (it is empty).",
            "The file “notes.txt” couldn’t be opened because the text encoding of its contents can’t be determined."
        ]
        for text in plain {
            XCTAssertFalse(ListenerErrorText.looksLikeCodeOrDump(text), "\"\(text)\"")
        }
    }

    func testFeedErrorsSayThePlainLineWithoutJargon() {
        let plain = "That link isn't a podcast or news feed. Check the address."
        for error in [FeedParserError.tooDeep, .unsupported, .malformed] {
            XCTAssertEqual(ListenerErrorText.message(for: error), plain, "\(error)")
        }
    }
}
