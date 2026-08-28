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

    func testArticleShortcutBuildsReadablePageHandoff() throws {
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let handoff = try AddArticleShortcutImport.makeHandoff(
            articleURL: try XCTUnwrap(URL(string: "https://example.com/article?id=38")),
            title: "  Shortcut Article  ",
            body: "\nArticle body from Safari Reader.\n",
            author: "  A. Reader  ",
            publishedAt: publishedAt,
            startListening: true
        )

        XCTAssertEqual(handoff.captureMode, .readablePage)
        XCTAssertEqual(handoff.contentFormat, .plainText)
        XCTAssertEqual(handoff.source.url, "https://example.com/article?id=38")
        XCTAssertEqual(handoff.source.title, "Shortcut Article")
        XCTAssertEqual(handoff.source.author, "A. Reader")
        XCTAssertEqual(handoff.source.publishedAt, ISO8601DateFormatter().string(from: publishedAt))
        XCTAssertEqual(handoff.text, "Article body from Safari Reader.")
        XCTAssertTrue(handoff.requestedContinuation.startSession)
        XCTAssertEqual(handoff.requestedContinuation.preferredPlaybackOwner, "app")
    }

    func testArticleShortcutRejectsUnsupportedURLAndEmptyArticleFields() throws {
        XCTAssertThrowsError(try AddArticleShortcutImport.makeHandoff(
            articleURL: try XCTUnwrap(URL(string: "file:///tmp/article.txt")),
            title: "Article",
            body: "Body"
        )) { error in
            XCTAssertEqual(error as? AddArticleShortcutError, .unsupportedURL)
        }

        XCTAssertThrowsError(try AddArticleShortcutImport.makeHandoff(
            articleURL: try XCTUnwrap(URL(string: "https://example.com/article")),
            title: "   ",
            body: "Body"
        )) { error in
            XCTAssertEqual(error as? AddArticleShortcutError, .missingTitle)
        }

        XCTAssertThrowsError(try AddArticleShortcutImport.makeHandoff(
            articleURL: try XCTUnwrap(URL(string: "https://example.com/article")),
            title: "Article",
            body: "  \n  "
        )) { error in
            XCTAssertEqual(error as? AddArticleShortcutError, .missingBody)
        }
    }

    func testArticleShortcutEnqueuesPayloadForAppImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-shortcut-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let store = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        let handoff = try AddArticleShortcutImport.makeHandoff(
            articleURL: try XCTUnwrap(URL(string: "https://example.com/enqueued")),
            title: "Enqueued Article",
            body: "Article text queued by an App Intent.",
            startListening: false
        )

        let openURL = try AddArticleShortcutImport.enqueue(
            handoff,
            store: store,
            payloadID: "shortcut-payload-38"
        )

        XCTAssertEqual(Gate5BrowserTextHandoffURL.payloadID(from: openURL), "shortcut-payload-38")
        XCTAssertEqual(try store.handoff(payloadID: "shortcut-payload-38"), handoff)
    }

    func testExactEmojiArticleImportPreservesSourceWhileSystemSpeechProjectionRemovesUnsafeContent() throws {
        let sourceText = try EmojiArticleRegressionFixture.browserMarkdown()
        let handoff = BrowserTextHandoff(
            itemId: "item-exact-emoji-browser-markdown",
            captureMode: .readablePage,
            source: BrowserTextSource(url: EmojiArticleRegressionFixture.sourceURL, title: EmojiArticleRegressionFixture.title),
            text: sourceText,
            contentFormat: .markdown
        )

        let sanitized = Gate1AppModel.sanitizedBrowserTextHandoff(handoff)
        let speech = SpeechTextNormalizer.projectForSystemSpeech(sanitized.text)

        XCTAssertEqual(sanitized.contentFormat, .markdown)
        for heading in EmojiArticleRegressionFixture.sectionHeadings {
            XCTAssertTrue(sanitized.text.contains("## \(heading)"))
        }
        XCTAssertTrue(sanitized.text.contains("💪💪🏻💪🏼💪🏽💪🏾💪🏿"))
        XCTAssertTrue(sanitized.text.contains("Language only truly lives"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("<video"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("<source"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("browser doesn't support"))
        XCTAssertFalse(speech.text.contains("💪"))
        XCTAssertFalse(speech.text.contains("⛲"))
        XCTAssertFalse(speech.text.localizedCaseInsensitiveContains("<video"))
        XCTAssertTrue(speech.text.contains("Language only truly lives"))
        XCTAssertTrue(SpeechTextNormalizer.isSystemSpeechSafe(speech.text))
        XCTAssertTrue(speech.text.allSatisfy { String($0).utf16.count == 1 })
        XCTAssertEqual(speech.text.count, speech.sourceOffsets.count)
        XCTAssertTrue(zip(speech.sourceOffsets, speech.sourceOffsets.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertTrue(speech.sourceOffsets.allSatisfy { 0...sanitized.text.count ~= $0 })

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        XCTAssertTrue(model.importBrowserText(handoff))
        XCTAssertEqual(model.selectedItem.status, "ready")
        XCTAssertEqual(
            model.selectedItem.chapters.map(\.title),
            EmojiArticleRegressionFixture.sectionHeadings
        )
    }

    func testPlainTextAndMarkdownHandoffsAreNotHTMLStripped() {
        for captureMode in [BrowserTextCaptureMode.selectedText, .markdownFile, .plainTextFile] {
            let handoff = BrowserTextHandoff(
                captureMode: captureMode,
                source: BrowserTextSource(url: "file:///fixture.md", title: "Deliberate Markup"),
                text: "Keep <video> as deliberate text 💪🏿.",
                contentFormat: captureMode == .markdownFile ? .markdown : .plainText
            )

            XCTAssertEqual(Gate1AppModel.sanitizedBrowserTextHandoff(handoff), handoff)
        }
    }

    func testBrowserTextPayloadURLParsesHandoffFromStore() throws {
        let payloadID = "payload-readable"
        let store = try makePayloadStore(payloadID: payloadID, payload: [
            "id": payloadID,
            "schemaVersion": "browser-text-handoff.v1",
            "itemId": "item-payload-readable",
            "captureMode": "readable_page",
            "contentFormat": "markdown",
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
        XCTAssertEqual(parsed.contentFormat, .markdown)
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

    func testIncomingBrowserPayloadDoesNotReplacePlaybackFromLibraryRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-browser-route-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let browserStore = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        let sourceStore = SourceLinkHandoffStore(baseDirectory: directory)
        let payloadID = "payload-browser-during-playback"
        try browserStore.save(BrowserTextHandoff(
            itemId: "item-browser-during-playback",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/during-playback", title: "Shared During Playback"),
            text: "Do not replace the active session.",
            contentFormat: .plainText
        ), payloadID: payloadID)
        let model = Gate1AppModel(
            sourceLinkHandoffStore: sourceStore,
            browserTextHandoffStore: browserStore,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let sessionID = model.snapshot.sessionId
        model.openHome()

        model.handleIncomingURL(Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID))

        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.itemId, activeItemID)
        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-browser-during-playback" })
        XCTAssertEqual(model.diagnostics["lastBrowserTextPayloadCleanup"], "imported_without_session_replacement")
        XCTAssertThrowsError(try browserStore.handoff(payloadID: payloadID))
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

    func testPendingMarkdownShareImportsMapWithoutReplacingPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-markdown-share-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let browserStore = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        let sourceStore = SourceLinkHandoffStore(baseDirectory: directory)
        let body = String(repeating: "Useful article content with enough spacing for listening. ", count: 70)
        let handoff = BrowserTextHandoff(
            itemId: "item-shared-markdown",
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "file:///HSA.md", title: "HSA Guide"),
            text: """
            # HSA Guide
            ### First use
            \(body)
            ### Second use
            \(body)
            ### Third use
            \(body)
            ### Fourth use
            \(body)
            ### Fifth use
            \(body)
            """,
            contentFormat: .markdown
        )
        try browserStore.save(handoff, payloadID: "payload-shared-markdown")
        let model = Gate1AppModel(
            sourceLinkHandoffStore: sourceStore,
            browserTextHandoffStore: browserStore,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let snapshotBeforeImport = model.snapshot

        model.importPendingSourceLinkHandoffs()
        try await waitFor("Markdown share import") {
            model.libraryItems.contains { $0.id == "item-shared-markdown" }
        }

        XCTAssertEqual(model.snapshot, snapshotBeforeImport)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertThrowsError(try browserStore.handoff(payloadID: "payload-shared-markdown"))

        model.openItem(id: "item-shared-markdown")
        XCTAssertEqual(model.selectedItem.title, "HSA Guide")
        XCTAssertFalse(model.selectedItem.chapters.isEmpty)
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

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let interval: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for \(description).")
    }
}
