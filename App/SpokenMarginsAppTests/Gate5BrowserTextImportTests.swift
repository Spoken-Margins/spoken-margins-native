import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate5BrowserTextImportTests: XCTestCase {
    func testReadablePagePayloadMapsToTypedHandoffWithoutExposingWebKitDetails() throws {
        let handoff = try AppOwnedReadablePageExtractor.handoff(from: [
            "text": "# The poverty of anti-tech thought\n\nReadable article body.",
            "source": [
                "url": "https://www.noahpinion.blog/p/the-poverty-of-anti-tech-thought",
                "title": "The poverty of anti-tech thought",
                "author": "Noah Smith"
            ]
        ])

        XCTAssertEqual(handoff.captureMode, .readablePage)
        XCTAssertEqual(handoff.contentFormat, .markdown)
        XCTAssertEqual(handoff.source.title, "The poverty of anti-tech thought")
        XCTAssertEqual(handoff.source.author, "Noah Smith")
        XCTAssertTrue(handoff.text.contains("Readable article body."))
    }

    func testReadablePagePayloadRejectsEmptyFallbackTextWithTypedError() {
        XCTAssertThrowsError(try AppOwnedReadablePageExtractor.handoff(from: [
            "text": "   ",
            "source": ["url": "https://example.com/article", "title": "Article"]
        ])) { error in
            XCTAssertEqual(error as? ReadablePageExtractionError, .invalidResult)
        }
    }

    private var temporaryDirectories: [URL] = []
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Several tests start playback. On a simulator where the terms were never
        // accepted, the first playback waits for the terms decision instead, so
        // these tests passed or failed depending on earlier tests' leftovers.
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        for (value, key) in [(priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey), (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey)] {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
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
        XCTAssertTrue(sanitized.text.contains("symbols only stay alive"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("<video"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("<source"))
        XCTAssertFalse(sanitized.text.localizedCaseInsensitiveContains("browser doesn't support"))
        XCTAssertFalse(speech.text.contains("💪"))
        XCTAssertFalse(speech.text.contains("⛲"))
        XCTAssertFalse(speech.text.localizedCaseInsensitiveContains("<video"))
        XCTAssertTrue(speech.text.contains("symbols only stay alive"))
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
            // The article's opening paragraphs, under its `#` title, are a chapter before the first section (#1435).
            [EmojiArticleRegressionFixture.title] + EmojiArticleRegressionFixture.sectionHeadings
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

    /// #1437: with something paused in the mini player, a share opens its item as it does with nothing loaded,
    /// and the paused item keeps its place.
    func testIncomingBrowserPayloadDoesNotReplacePlaybackFromLibraryRoot() async throws {
        try await checkIncomingBrowserPayloadDuringPlayback(pausing: true)
    }

    /// The same share while the item plays: it shows the shared item and the audio carries on.
    func testIncomingBrowserPayloadShowsItsItemWhileSomethingPlays() async throws {
        try await checkIncomingBrowserPayloadDuringPlayback(pausing: false)
    }

    private func checkIncomingBrowserPayloadDuringPlayback(pausing: Bool) async throws {
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
        if pausing { model.pause() }
        let statusBefore = model.snapshot.status
        XCTAssertEqual(statusBefore.isPlaybackActive, !pausing)
        let positionBefore = model.snapshot.currentTextStart
        model.openHome()

        model.handleIncomingURL(Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID))
        // The payload file is read and deleted off the main thread (#2510), so the import lands a moment later.
        try await waitFor("shared payload import") {
            model.diagnostics["lastBrowserTextPayloadCleanup"] == "imported_without_session_replacement"
        }

        // #1437: the shared item opens as it does with nothing loaded; the paused item keeps its session.
        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, "item-browser-during-playback")
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.itemId, activeItemID)
        XCTAssertEqual(model.snapshot.status, statusBefore, "the share starts and stops nothing")
        XCTAssertEqual(model.snapshot.currentTextStart, positionBefore)
        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-browser-during-playback" })
        XCTAssertEqual(model.statusMessage, "Added Shared During Playback to Library without changing Now Playing.")
        XCTAssertEqual(model.diagnostics["lastBrowserTextPayloadCleanup"], "imported_without_session_replacement")
        XCTAssertThrowsError(try browserStore.handoff(payloadID: payloadID))
    }

    /// Drives the app's own route for a shared payload (#1049, LNK-04): the model, not the test, deletes the
    /// payload once the import succeeds, so the launch sweep can't import it again.
    func testPayloadIsDeletedAfterSuccessfulImport() async throws {
        let payloadID = "payload-delete"
        let store = try makePayloadStore(payloadID: payloadID, payload: deletablePayload(payloadID: payloadID))
        let model = Gate1AppModel(
            browserTextHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertFalse(model.libraryItems.contains { $0.id == "item-payload-delete" })

        model.handleIncomingURL(Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID))
        try await waitFor("payload deleted after import") { (try? store.pendingPayloadIDs()) == [] }

        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-payload-delete" })
        XCTAssertEqual(model.diagnostics["lastBrowserTextImport"], "item-payload-delete")
        XCTAssertThrowsError(try store.handoff(payloadID: payloadID)) { error in
            XCTAssertEqual(error as? Gate5BrowserTextHandoffStoreError, .missingPayload(payloadID))
        }
        XCTAssertEqual(try store.pendingPayloadIDs(), [])
    }

    /// The failure twin: when the import fails (here the Library database can't be opened), the shared text
    /// stays in the store for the next launch instead of being lost.
    func testPayloadIsKeptWhenImportFails() async throws {
        let payloadID = "payload-keep"
        let store = try makePayloadStore(payloadID: payloadID, payload: deletablePayload(payloadID: payloadID))
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-gate5-blocked-\(UUID().uuidString)")
        temporaryDirectories.append(blocker)
        try Data("not a folder".utf8).write(to: blocker)
        let model = Gate1AppModel(
            browserTextHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: blocker.appendingPathComponent("Library.sqlite")
        )
        XCTAssertFalse(model.hasActiveSession)

        model.handleIncomingURL(Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID))
        try await waitFor("failed payload import") { model.lastError != nil }

        XCTAssertNil(model.diagnostics["lastBrowserTextImport"])
        XCTAssertEqual(try store.handoff(payloadID: payloadID).itemId, "item-payload-delete")
        XCTAssertEqual(try store.pendingPayloadIDs(), [payloadID])
    }

    private func deletablePayload(payloadID: String) -> [String: Any] {
        [
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
        ]
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

    /// #662: the handoff the share extension writes for a ChatGPT response shared as plain text,
    /// key for key, reaches the Library with its whole text and leaves playback alone.
    func testPendingSharedTextFromAnotherAppImportsWithoutReplacingPlayback() async throws {
        let response = """
        Here's the completed review. My recommendation is to ship the fix first.

        ## What changed
        The share extension keeps the whole response. See https://example.com/notes for more.
        """
        let browserStore = try makePayloadStore(payloadID: "browser-text-shared-662", payload: [
            "id": "browser-text-shared-662",
            "itemId": "item-shared-text-662",
            "schemaVersion": "browser-text-handoff.v1",
            "captureMode": "plain_text_file",
            "contentFormat": "markdown",
            "source": ["url": "shared-text://share-sheet", "title": "Here's the completed review. My recommendation is to"],
            "text": response,
            "requestedContinuation": ["startSession": false, "preferredPlaybackOwner": "app"],
            "createdAt": "2026-10-10T03:00:00Z"
        ])
        let directory = try XCTUnwrap(temporaryDirectories.last)
        let model = Gate1AppModel(
            sourceLinkHandoffStore: SourceLinkHandoffStore(baseDirectory: directory),
            browserTextHandoffStore: browserStore,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let snapshotBeforeImport = model.snapshot

        model.importPendingSourceLinkHandoffs()
        try await waitFor("Shared text import") {
            model.libraryItems.contains { $0.id == "item-shared-text-662" }
        }

        XCTAssertEqual(model.snapshot, snapshotBeforeImport)
        XCTAssertThrowsError(try browserStore.handoff(payloadID: "browser-text-shared-662"))
        model.openItem(id: "item-shared-text-662")
        XCTAssertEqual(model.selectedItem.title, "Here's the completed review. My recommendation is to")
        XCTAssertTrue(model.selectedItem.text.contains("ship the fix first"))
        XCTAssertTrue(model.selectedItem.text.contains("keeps the whole response"))
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
