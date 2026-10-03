import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #310: an error banner vanished after 6 seconds and the failure couldn't be read again.
@MainActor
final class FeedbackBannerTests: XCTestCase {
    func testAFailureOnAnItemStaysReadableOnThatItemAfterItsBannerCloses() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.screen, .item)

        // Reports a failure: the item isn't in Recently Deleted.
        model.permanentlyDeleteItem(id: "item-pill")
        let message = "Move the item to Recently Deleted before deleting it permanently."
        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message, message)

        model.dismissFeedback()
        model.openHome()
        model.openItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message, message)

        model.clearLastFailure(itemId: "item-pill")
        XCTAssertNil(model.itemFailures.lastFailure(itemId: "item-pill"))
    }

    func testAFailureAwayFromAnItemIsNotPinnedToOne() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.openItem(id: "item-pill")
        model.openHome()
        XCTAssertEqual(model.screen, .home)

        model.permanentlyDeleteItem(id: "item-pill")

        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertNil(model.itemFailures.lastFailure(itemId: "item-pill"))
    }

    func testAConfirmationDoesNotCoverAnErrorThatOffersRetry() {
        let retryable = UserFeedbackEvent(kind: .error, message: "The request timed out.", retry: .init(key: "test") {})
        let plain = UserFeedbackEvent(kind: .error, message: "Clipboard does not contain text.")
        let confirmation = UserFeedbackEvent(kind: .success, message: "Copied.")

        XCTAssertFalse(retryable.mayBeReplaced(by: confirmation))
        XCTAssertTrue(retryable.mayBeReplaced(by: plain))
        XCTAssertTrue(plain.mayBeReplaced(by: confirmation))
    }

    func testFailedTimelineSummaryStaysOnItsItemAfterBannerCloses() async throws {
        try await withPendingLocalSummary { model, summarizer in
            XCTAssertEqual(model.screen, .timeline)
            let startedAt = Date()
            await summarizer.fail()
            try await waitForSummaryFailure(model)

            let failure = try XCTUnwrap(model.itemFailures.lastFailure(itemId: "item-pill"))
            XCTAssertEqual(failure.message, model.feedbackEvent?.message)
            XCTAssertGreaterThanOrEqual(failure.occurredAt, startedAt)
            XCTAssertLessThanOrEqual(failure.occurredAt, Date())
            XCTAssertEqual(model.feedbackEvent?.kind, .error)
            XCTAssertEqual(model.feedbackEvent?.retry?.key, "summary")
            XCTAssertNil(FeedbackBannerPolicy.autoDismissSeconds(for: .error))
            let bannerId = model.feedbackEvent?.id
            model.openItem(id: "item-pill")
            XCTAssertEqual(model.feedbackEvent?.id, bannerId, "Opening the item must not cover its Retry banner.")

            model.dismissFeedback()
            model.openHome()
            model.openItem(id: "item-pill")
            XCTAssertNil(model.feedbackEvent)
            XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill"), failure)
        }
    }

    func testFailedTimelineSummaryStaysOnOriginalItemAfterOpeningAnotherItem() async throws {
        try await withPendingLocalSummary { model, summarizer in
            let otherItemId = try XCTUnwrap(model.libraryItems.first { $0.id != "item-pill" }?.id)
            model.openItem(id: otherItemId)
            XCTAssertEqual(model.screen, .item)
            XCTAssertEqual(model.selectedItem.id, otherItemId)

            await summarizer.fail()
            try await waitForSummaryFailure(model)

            XCTAssertEqual(model.selectedItem.id, otherItemId)
            XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message,
                           model.feedbackEvent?.message)
            XCTAssertNotNil(model.itemFailures.lastFailure(itemId: "item-pill"))
            XCTAssertNil(model.itemFailures.lastFailure(itemId: otherItemId))
            XCTAssertEqual(model.feedbackEvent?.retry?.key, "summary")
        }
    }

    private func withPendingLocalSummary(
        _ check: (Gate1AppModel, PendingFailingSummaryClient) async throws -> Void
    ) async throws {
        let version = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let date = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            if let version {
                UserDefaults.standard.set(version, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SpokenMarginsTerms.acceptanceVersionKey)
            }
            if let date {
                UserDefaults.standard.set(date, forKey: SpokenMarginsTerms.acceptanceDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SpokenMarginsTerms.acceptanceDateKey)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        let summarizer = PendingFailingSummaryClient()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: summarizer
        )
        model.resetAndSeed()
        model.importTitle = "Another article"
        model.importText = "A different source that the listener can open while a summary is pending."
        model.importTextItem(startListening: false)
        XCTAssertEqual(model.libraryItems.count, 2)
        model.startItem(id: "item-pill")
        model.pause()
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Does this premise support the conclusion?")
        XCTAssertTrue(model.canSummarizeInterjections)
        model.openTimeline()
        XCTAssertEqual(model.screen, .timeline)
        model.summarize()
        let didStart = await summarizer.waitUntilRequested()
        XCTAssertTrue(didStart, "The summary must start before navigation or failure.")
        do {
            try await check(model, summarizer)
        } catch {
            await summarizer.fail()
            throw error
        }
        await summarizer.fail()
    }

    private func waitForSummaryFailure(_ model: Gate1AppModel) async throws {
        for _ in 0..<100 {
            if model.diagnostics["lastSummaryMode"] == "apple_foundation_failed" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the local summary failure.")
    }
}

private actor PendingFailingSummaryClient: LocalFoundationModelClient {
    private var pending: CheckedContinuation<String, Error>?

    nonisolated func availability() -> LocalFoundationModelAvailability { .available }

    func summarizeInterjections(context: String) async throws -> String {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func waitUntilRequested() async -> Bool {
        for _ in 0..<100 {
            if pending != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func fail() {
        pending?.resume(throwing: LocalFoundationModelError.invalidInterjectionSummary)
        pending = nil
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }
}
