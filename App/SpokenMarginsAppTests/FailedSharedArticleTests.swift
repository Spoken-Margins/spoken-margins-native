import Combine
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #1972: the share sheet says "Saved" before the app imports the article. When the import fails, the listener
/// is told, with a way to the Import Inbox, instead of waiting for an article that isn't coming.
@MainActor
final class FailedSharedArticleTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testAnArticleThatCannotBeImportedIsAnnouncedAndKeptForRetry() async throws {
        let (model, store) = try makeModel(failing: ["One"], mismatched: [])

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the failure banner") { model.feedbackEvent?.message.contains("shared article") == true }

        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.message, "1 shared article couldn't be added.")
        XCTAssertEqual(try XCTUnwrap(event.action).title, "See why")
        XCTAssertEqual(try store.pendingPayloadIDs(), [], "The failed share leaves the queue, so it can't be announced twice")
        XCTAssertEqual(try store.failedHandoffs().count, 1, "The payload is kept in the Import Inbox for retry")
    }

    func testSeeWhyOpensSettingsWhereTheInboxListsAPlainReason() async throws {
        let (model, _) = try makeModel(failing: ["One"], mismatched: [])
        model.importPendingSourceLinkHandoffs()
        try await waitFor("the failure banner") { model.feedbackEvent?.message.contains("shared article") == true }

        try XCTUnwrap(model.feedbackEvent?.action).perform()
        model.refreshImportInbox()

        XCTAssertEqual(model.requestedExperienceRoot, .settings)
        let entry = try XCTUnwrap(model.importInbox.first)
        XCTAssertEqual(entry.reason, ImportInboxReason.plain(entry.reason), "The Inbox shows a sentence, not the error's code")
    }

    func testSeveralFailuresGetOneBannerWithTheCount() async throws {
        let (model, _) = try makeModel(failing: ["One", "Two", "Three"], mismatched: [])

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the failure banner") { model.feedbackEvent?.message.contains("shared article") == true }

        XCTAssertEqual(model.feedbackEvent?.message, "3 shared articles couldn't be added.")
    }

    func testAnUnreadablePayloadStaysQuiet() async throws {
        let (model, store) = try makeModel(failing: [], mismatched: ["bad-payload"])
        // Every banner the drain presents is recorded, so a shared-article banner that a later one (such as the
        // fixture's "Library bootstrap failed", which lands on its own schedule) replaced is still caught, and
        // that unrelated banner can't fail this test (#2360).
        var presented: [String] = []
        let recording = model.$feedbackEvent.sink { event in
            if let event { presented.append(event.message) }
        }
        defer { recording.cancel() }

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the drain") { model.diagnostics["pendingBrowserTextPayload:bad-payload"] != nil }

        XCTAssertEqual(model.diagnostics["pendingBrowserTextPayload:bad-payload"], "deleted_invalid_payload")
        XCTAssertEqual(
            presented.filter { $0.contains("shared article") }, [],
            "An unreadable payload is dropped without a shared-article banner"
        )
        XCTAssertEqual(try store.failedHandoffs().count, 0)
    }

    func testTheMessageCountsOneAndMany() {
        XCTAssertEqual(Gate1AppModel.failedSharedArticlesMessage(count: 1), "1 shared article couldn't be added.")
        XCTAssertEqual(Gate1AppModel.failedSharedArticlesMessage(count: 2), "2 shared articles couldn't be added.")
    }

    /// A model whose library file can't open, so every valid payload fails to import, as in `Gate5BrowserTextImportTests`.
    private func makeModel(failing titles: [String], mismatched: [String]) throws -> (Gate1AppModel, Gate5BrowserTextHandoffStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-failed-share-\(UUID().uuidString)", isDirectory: true)
        temporaryURLs.append(directory)
        let store = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        for (index, title) in titles.enumerated() {
            try store.save(BrowserTextHandoff(
                itemId: "item-failed-share-\(index)",
                captureMode: .readablePage,
                source: BrowserTextSource(url: "https://example.com/failed-share-\(index)", title: title),
                text: "# \(title)\n\nThe first paragraph of \(title), long enough to import as an article.",
                contentFormat: .markdown,
                requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
            ), payloadID: "payload-failed-share-\(index)")
        }
        // A payload whose own id differs from its file name is `invalidPayload`, which stays quiet.
        let payloads = directory.appendingPathComponent("BrowserTextHandoffs", isDirectory: true)
        for id in mismatched {
            try store.save(BrowserTextHandoff(
                itemId: "item-mismatched",
                captureMode: .readablePage,
                source: BrowserTextSource(url: "https://example.com/mismatched", title: "Mismatched"),
                text: "# Mismatched\n\nText.",
                contentFormat: .markdown,
                requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
            ), payloadID: "original-\(id)")
            try FileManager.default.moveItem(
                at: payloads.appendingPathComponent("original-\(id)").appendingPathExtension("json"),
                to: payloads.appendingPathComponent(id).appendingPathExtension("json")
            )
        }
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-failed-share-blocked-\(UUID().uuidString)")
        temporaryURLs.append(blocker)
        try Data("not a folder".utf8).write(to: blocker)
        let model = Gate1AppModel(
            sourceLinkHandoffStore: SourceLinkHandoffStore(baseDirectory: directory),
            browserTextHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: blocker.appendingPathComponent("Library.sqlite")
        )
        model.dismissFeedback()
        return (model, store)
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            elapsed += 10_000_000
        }
        XCTFail("Timed out waiting for \(description).")
    }
}
