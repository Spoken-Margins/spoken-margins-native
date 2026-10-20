import Foundation
import XCTest
@testable import SessionKit

/// The `<scheme>://browser-text` links that carry a browser text handoff into the app (moved from the app target, #318).
final class BrowserTextHandoffURLTests: XCTestCase {
    private let codec = BrowserTextHandoffURL(scheme: "spokenmargins")

    func testBrowserTextURLParsesHandoff() throws {
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-url-test",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/readable", title: "Readable Page", author: "A. Writer"),
            text: "Readable page text.",
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "browser_or_app")
        )

        let parsed = try XCTUnwrap(codec.handoff(from: codec.url(for: handoff)))

        XCTAssertEqual(parsed.itemId, "item-browser-url-test")
        XCTAssertEqual(parsed.captureMode, .readablePage)
        XCTAssertEqual(parsed.source.url, "https://example.com/readable")
        XCTAssertEqual(parsed.source.title, "Readable Page")
        XCTAssertEqual(parsed.source.author, "A. Writer")
        XCTAssertEqual(parsed.text, "Readable page text.")
        XCTAssertEqual(parsed.requestedContinuation.startSession, true)
        XCTAssertEqual(parsed.requestedContinuation.preferredPlaybackOwner, "browser_or_app")
    }

    func testTextThatNeedsEscapingSurvivesTheRoundTrip() throws {
        let texts = [
            "Tom & Jerry = 100% fun + more? Yes #1",
            "Line one\nLine two\n\nLine four",
            "Emoji 🎧 and accents café naïve, 日本語",
            "   padded text   ",
            String(repeating: "A long paragraph. ", count: 2_000)
        ]
        for text in texts {
            let handoff = BrowserTextHandoff(
                captureMode: .selectedText,
                source: BrowserTextSource(url: "https://example.com/a?b=c&d=e#f", title: "Title & more: 100%"),
                text: text
            )
            let parsed = try XCTUnwrap(codec.handoff(from: codec.url(for: handoff)), "text \(text.prefix(20))")
            XCTAssertEqual(parsed.text, text)
            XCTAssertEqual(parsed.source.url, "https://example.com/a?b=c&d=e#f")
            XCTAssertEqual(parsed.source.title, "Title & more: 100%")
        }
    }

    func testOptionalFieldsAreWrittenOnlyWhenPresent() throws {
        let bare = BrowserTextHandoff(
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com", title: "T"),
            text: "Body."
        )
        let names = Set(URLComponents(url: codec.url(for: bare), resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertEqual(names, ["captureMode", "title", "url", "text", "startSession"])

        let full = BrowserTextHandoff(
            itemId: "i",
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "https://example.com", title: "T", author: "A", publishedAt: "2026-01-02"),
            text: "Body.",
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
        let parsed = try XCTUnwrap(codec.handoff(from: codec.url(for: full)))
        XCTAssertEqual(parsed.itemId, "i")
        XCTAssertEqual(parsed.captureMode, .markdownFile)
        XCTAssertEqual(parsed.source.author, "A")
        XCTAssertEqual(parsed.source.publishedAt, "2026-01-02")
        XCTAssertFalse(parsed.requestedContinuation.startSession)
        XCTAssertEqual(parsed.requestedContinuation.preferredPlaybackOwner, "app")
    }

    func testOnlyThisSchemeAndHostAreBrowserTextLinks() throws {
        XCTAssertTrue(codec.isBrowserTextURL(try XCTUnwrap(URL(string: "spokenmargins://browser-text?text=a&url=b"))))
        XCTAssertFalse(codec.isBrowserTextURL(try XCTUnwrap(URL(string: "spokenmargins-legacy://browser-text?text=a&url=b"))))
        XCTAssertFalse(codec.isBrowserTextURL(try XCTUnwrap(URL(string: "spokenmargins://open?text=a&url=b"))))
        XCTAssertFalse(codec.isBrowserTextURL(try XCTUnwrap(URL(string: "https://browser-text/?text=a&url=b"))))

        let legacy = BrowserTextHandoffURL(scheme: "spokenmargins-legacy")
        let link = try XCTUnwrap(URL(string: "spokenmargins-legacy://browser-text?text=a&url=https%3A%2F%2Fexample.com"))
        XCTAssertTrue(legacy.isBrowserTextURL(link))
        XCTAssertNotNil(legacy.handoff(from: link))
        XCTAssertNil(codec.handoff(from: link), "a link for the other build flavor is not this build's")
        XCTAssertEqual(legacy.url(forPayloadID: "p").scheme, "spokenmargins-legacy")
    }

    func testIncompleteOrAmbiguousLinksAreNotHandoffs() throws {
        let cases: [(String, String)] = [
            ("no text", "spokenmargins://browser-text?url=https%3A%2F%2Fexample.com"),
            ("empty text", "spokenmargins://browser-text?text=&url=https%3A%2F%2Fexample.com"),
            ("blank text", "spokenmargins://browser-text?text=%20%0A%20&url=https%3A%2F%2Fexample.com"),
            ("no source", "spokenmargins://browser-text?text=Body"),
            ("blank source", "spokenmargins://browser-text?text=Body&url=%20"),
            ("a payload id beside inline text", "spokenmargins://browser-text?payloadId=p&text=Body&url=https%3A%2F%2Fexample.com"),
            ("a key with no value", "spokenmargins://browser-text?text&url=https%3A%2F%2Fexample.com")
        ]
        for (label, string) in cases {
            XCTAssertNil(codec.handoff(from: try XCTUnwrap(URL(string: string))), label)
        }
    }

    func testDefaultsFillMissingTitleModeAndFlags() throws {
        let fallbackSource = try XCTUnwrap(codec.handoff(
            from: try XCTUnwrap(URL(string: "spokenmargins://browser-text?text=Body&externalReference=https%3A%2F%2Fnews.example.com%2Fa%3Fid%3D1"))
        ))
        XCTAssertEqual(fallbackSource.source.url, "https://news.example.com/a?id=1")
        XCTAssertEqual(fallbackSource.source.title, "news.example.com", "no title falls back to the host")
        XCTAssertEqual(fallbackSource.captureMode, .selectedText)
        XCTAssertFalse(fallbackSource.requestedContinuation.startSession)

        let unknownMode = try XCTUnwrap(codec.handoff(
            from: try XCTUnwrap(URL(string: "spokenmargins://browser-text?text=Body&url=notaurl&captureMode=teleport"))
        ))
        XCTAssertEqual(unknownMode.captureMode, .selectedText)
        XCTAssertEqual(unknownMode.source.title, "Browser Text", "a source with no host has no host to borrow")
    }

    func testStartSessionAcceptsOnlyTheTruthyWords() throws {
        for (value, expected) in [("1", true), ("true", true), ("TRUE", true), ("Yes", true), ("0", false), ("false", false), ("no", false), ("", false), ("2", false)] {
            let link = try XCTUnwrap(URL(string: "spokenmargins://browser-text?text=Body&url=https%3A%2F%2Fexample.com&startSession=\(value)"))
            XCTAssertEqual(codec.handoff(from: link)?.requestedContinuation.startSession, expected, "startSession=\(value)")
        }
    }

    func testPayloadLinksCarryOnlyTheIDAndResolveThroughTheStore() throws {
        let link = codec.url(forPayloadID: "shortcut-payload-38")
        XCTAssertEqual(codec.payloadID(from: link), "shortcut-payload-38")
        XCTAssertTrue(codec.isBrowserTextURL(link))
        XCTAssertNil(codec.handoff(from: link), "the inline reader does not open a payload link")
        XCTAssertNil(codec.payloadID(from: try XCTUnwrap(URL(string: "spokenmargins://browser-text?text=Body"))))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserTextHandoffURLTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        let handoff = BrowserTextHandoff(
            itemId: "stored",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/stored", title: "Stored"),
            text: "Stored text."
        )
        try store.save(handoff, payloadID: "shortcut-payload-38")

        XCTAssertEqual(try codec.handoff(from: link, store: store), handoff)
        XCTAssertThrowsError(try codec.handoff(from: codec.url(forPayloadID: "missing"), store: store))
    }

    func testStoreOverloadFallsBackToInlineLinksAndRejectsOthers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserTextHandoffURLTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        let inline = BrowserTextHandoff(
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com", title: "T"),
            text: "Inline."
        )
        XCTAssertEqual(try codec.handoff(from: codec.url(for: inline), store: store).text, "Inline.")
        XCTAssertThrowsError(try codec.handoff(from: XCTUnwrap(URL(string: "spokenmargins://browser-text")), store: store)) { error in
            XCTAssertEqual(error as? Gate5BrowserTextHandoffStoreError, .invalidPayload("unsupported browser text URL"))
        }
    }
}
