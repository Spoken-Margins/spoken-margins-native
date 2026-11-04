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

    /// #3317: behind a friendly prefix, a Foundation dump still becomes the generic next step, and the prefix stays so the
    /// line still says what failed. These are the prefixes the app builds from an error.
    func testEveryPrefixKeepsItsWordsAndDropsTheFoundationDump() {
        let dump = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "The operation couldn\u{2019}t be completed. (NSCocoaErrorDomain error 513.)"
        ])
        let prefixes = [
            "Delivery needs attention:", "Couldn't use that folder:", "Folder selection failed:",
            "Couldn't save your Margin Output settings:", "Sending needs attention:",
            "Sending is off, but the history of what was sent could not be reset:",
            "Couldn't save the spoken Margin:", "Couldn't save the live session:", "Couldn't save:",
            "Couldn't save your agreement:", "Audio preparation paused:", "Source context could not be recovered:",
            "The file couldn't be read."
        ]
        for prefix in prefixes {
            let line = ListenerErrorText.line(prefix: prefix, error: dump)
            XCTAssertEqual(line, "\(prefix) \(ListenerErrorText.fallback)")
            XCTAssertFalse(line.contains("Error Domain"), line)
            XCTAssertFalse(line.contains("error 513"), line)
        }
    }

    func testAPlainReasonFollowsItsPrefix() {
        XCTAssertEqual(
            ListenerErrorText.line(prefix: "Couldn't use that folder:", error: PlainError()),
            "Couldn't use that folder: This PDF is only pictures of pages, so there is no text to read aloud.")
    }
}
