import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate5BrowserTextImportTests: XCTestCase {
    func testBrowserTextURLParsesHandoff() throws {
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-url-test",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/readable", title: "Readable Page", author: "A. Writer"),
            text: "Readable page text.",
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "browser_or_app")
        )

        let parsed = try XCTUnwrap(Gate5BrowserTextHandoffURL.handoff(from: Gate5BrowserTextHandoffURL.url(for: handoff)))

        XCTAssertEqual(parsed.itemId, "item-browser-url-test")
        XCTAssertEqual(parsed.captureMode, .readablePage)
        XCTAssertEqual(parsed.source.url, "https://example.com/readable")
        XCTAssertEqual(parsed.source.title, "Readable Page")
        XCTAssertEqual(parsed.source.author, "A. Writer")
        XCTAssertEqual(parsed.text, "Readable page text.")
        XCTAssertEqual(parsed.requestedContinuation.startSession, true)
        XCTAssertEqual(parsed.requestedContinuation.preferredPlaybackOwner, "browser_or_app")
    }

    func testBrowserTextImportStartsPlaybackAndPreservesSourceURL() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-app-test",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/app-test", title: "App Test Page"),
            text: "Text captured from a browser page.",
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "browser_or_app")
        )

        model.importBrowserText(handoff)

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.itemId, "item-browser-app-test")
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.selectedItem.title, "App Test Page")
        XCTAssertEqual(model.selectedItem.externalReference, "https://example.com/app-test")
        XCTAssertEqual(model.diagnostics["lastBrowserTextImport"], "item-browser-app-test")
    }

    func testIncomingBrowserTextURLRoutesToGate5Import() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        let url = Gate5BrowserTextHandoffURL.url(for: BrowserTextHandoff(
            itemId: "item-browser-url-route",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/route", title: "Route Page"),
            text: "Browser route text.",
            requestedContinuation: BrowserTextContinuation(startSession: false)
        ))

        model.handleIncomingURL(url)

        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.snapshot.itemId, "item-browser-url-route")
        XCTAssertEqual(model.selectedItem.externalReference, "https://example.com/route")
        XCTAssertEqual(model.statusMessage, "Imported browser text from Route Page.")
    }
}
