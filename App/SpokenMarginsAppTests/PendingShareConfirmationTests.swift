import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #828: Safari shares imported at launch or foreground end with the same "Added <title> to Library."
/// confirmation as other adds. One share offers Play now when nothing is in Now Playing; several share one
/// message with no button. Nothing plays by itself.
@MainActor
final class PendingShareConfirmationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testOneShareWithNothingPlayingOffersPlayNowAndOnlyTheTapPlays() async throws {
        let model = try makeModel(sharing: ["One Shared Page"])

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the confirmation") { model.feedbackEvent != nil }

        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.message, "Added One Shared Page to Library.")
        let action = try XCTUnwrap(event.action, "Play now must be offered when Now Playing is empty")
        XCTAssertEqual(action.title, "Play now")
        XCTAssertNil(model.snapshot.sessionId, "A share never autoplays")

        action.perform()
        let added = try XCTUnwrap(model.libraryItems.first { $0.title == "One Shared Page" })
        XCTAssertEqual(model.snapshot.itemId, added.id)
        XCTAssertEqual(model.screen, .playback)
    }

    func testSeveralSharesGetOneMessageWithNoPlayNow() async throws {
        let model = try makeModel(sharing: ["Share A", "Share B", "Share C"])

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the confirmation") { model.feedbackEvent != nil }

        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.message, "Added 3 items to Library.")
        XCTAssertNil(event.action)
        XCTAssertNil(model.snapshot.sessionId, "Shares never autoplay")
        for title in ["Share A", "Share B", "Share C"] {
            XCTAssertTrue(model.libraryItems.contains { $0.title == title }, title)
        }
    }

    func testSharesDuringPlaybackLeaveNowPlayingAloneAndOfferNoPlayNow() async throws {
        let model = try makeModel(sharing: ["During One"])
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let before = model.snapshot

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the confirmation") { model.feedbackEvent != nil }

        XCTAssertEqual(model.feedbackEvent?.message, "Added During One to Library without changing Now Playing.")
        XCTAssertNil(model.feedbackEvent?.action)
        XCTAssertEqual(model.snapshot, before)
    }

    func testSeveralSharesDuringPlaybackSayNowPlayingIsUnchanged() async throws {
        let model = try makeModel(sharing: ["During A", "During B"])
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let before = model.snapshot

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the confirmation") { model.feedbackEvent != nil }

        XCTAssertEqual(model.feedbackEvent?.message, "Added 2 items to Library without changing Now Playing.")
        XCTAssertNil(model.feedbackEvent?.action)
        XCTAssertEqual(model.snapshot, before)
    }

    func testNoPendingSharesSaysNothing() async throws {
        let model = try makeModel(sharing: [])

        model.importPendingSourceLinkHandoffs()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(model.feedbackEvent)
    }

    private func makeModel(sharing titles: [String]) throws -> Gate1AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-pending-share-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let browserStore = Gate5BrowserTextHandoffStore(baseDirectory: directory)
        for (index, title) in titles.enumerated() {
            try browserStore.save(BrowserTextHandoff(
                itemId: "item-pending-share-\(index)",
                captureMode: .readablePage,
                source: BrowserTextSource(url: "https://example.com/pending-share-\(index)", title: title),
                text: "# \(title)\n\nThe first paragraph of \(title), long enough to import as an article.",
                contentFormat: .markdown,
                requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
            ), payloadID: "payload-pending-share-\(index)")
        }
        let model = Gate1AppModel(
            sourceLinkHandoffStore: SourceLinkHandoffStore(baseDirectory: directory),
            browserTextHandoffStore: browserStore,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        model.declineCurrentTerms() // a fresh simulator otherwise parks playback on the voice choice
        model.dismissFeedback()
        return model
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
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
