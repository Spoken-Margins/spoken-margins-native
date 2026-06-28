import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate5BrowserTextImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

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

    func testBrowserTextPayloadURLParsesHandoffFromStore() throws {
        let payloadID = "payload-readable"
        let store = try makePayloadStore(payloadID: payloadID, payload: [
            "id": payloadID,
            "schemaVersion": "browser-text-handoff.v1",
            "itemId": "item-payload-readable",
            "captureMode": "readable_page",
            "source": [
                "url": "https://example.com/payload",
                "title": "Payload Page",
                "author": "A. Writer"
            ],
            "text": " Long readable page text. ",
            "requestedContinuation": [
                "startSession": true,
                "preferredPlaybackOwner": "app"
            ]
        ])

        let parsed = try Gate5BrowserTextHandoffURL.handoff(
            from: Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID),
            store: store
        )

        XCTAssertEqual(parsed.itemId, "item-payload-readable")
        XCTAssertEqual(parsed.captureMode, .readablePage)
        XCTAssertEqual(parsed.source.url, "https://example.com/payload")
        XCTAssertEqual(parsed.source.title, "Payload Page")
        XCTAssertEqual(parsed.source.author, "A. Writer")
        XCTAssertEqual(parsed.text, "Long readable page text.")
        XCTAssertEqual(parsed.requestedContinuation.startSession, true)
        XCTAssertEqual(parsed.requestedContinuation.preferredPlaybackOwner, "app")
    }

    func testBrowserTextPayloadRejectsMissingText() throws {
        let payloadID = "payload-empty"
        let store = try makePayloadStore(payloadID: payloadID, payload: [
            "id": payloadID,
            "schemaVersion": "browser-text-handoff.v1",
            "captureMode": "selected_text",
            "source": [
                "url": "https://example.com/empty",
                "title": "Empty"
            ],
            "text": "   "
        ])

        XCTAssertThrowsError(try store.handoff(payloadID: payloadID)) { error in
            XCTAssertEqual(error as? Gate5BrowserTextHandoffStoreError, .invalidPayload("text is required"))
        }
    }

    func testBrowserTextImportStartsPlaybackAndPreservesSourceURL() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
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
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
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

    func testPayloadIsDeletedAfterSuccessfulImport() throws {
        let payloadID = "payload-delete"
        let store = try makePayloadStore(payloadID: payloadID, payload: [
            "id": payloadID,
            "schemaVersion": "browser-text-handoff.v1",
            "itemId": "item-payload-delete",
            "captureMode": "selected_text",
            "source": [
                "url": "https://example.com/delete",
                "title": "Delete Page"
            ],
            "text": "Browser text to import.",
            "requestedContinuation": [
                "startSession": true,
                "preferredPlaybackOwner": "app"
            ]
        ])
        let handoff = try store.handoff(payloadID: payloadID)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        let success = model.importBrowserText(handoff)
        if success {
            try store.deletePayload(payloadID: payloadID)
        }

        XCTAssertTrue(success)
        XCTAssertThrowsError(try store.handoff(payloadID: payloadID)) { error in
            XCTAssertEqual(error as? Gate5BrowserTextHandoffStoreError, .missingPayload(payloadID))
        }
    }

    private func makePayloadStore(payloadID: String, payload: [String: Any]) throws -> Gate5BrowserTextHandoffStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-gate5-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let payloadDirectory = directory.appendingPathComponent("BrowserTextHandoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        let payloadURL = payloadDirectory.appendingPathComponent(payloadID).appendingPathExtension("json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: payloadURL)
        return Gate5BrowserTextHandoffStore(baseDirectory: directory)
    }
}
