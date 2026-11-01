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

    /// #784: with nothing in Now Playing, the add confirmation offers Play now, and only the tap plays.
    func testAnAddWithNothingPlayingOffersPlayNowAndOnlyTheTapPlays() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms() // a fresh simulator otherwise parks playback on the voice choice
        XCTAssertTrue(model.nowPlayingIsEmpty)
        model.importTitle = "Play Now Article"
        model.importText = "A short article the listener adds while nothing is playing."
        model.importTextItem(startListening: false)

        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.kind, .success)
        XCTAssertEqual(event.message, "Added Play Now Article to Library.")
        let action = try XCTUnwrap(event.action, "Play now must be offered when Now Playing is empty")
        XCTAssertEqual(action.title, "Play now")
        XCTAssertEqual(action.accessibilityLabel, "Play now, Play Now Article")
        XCTAssertNil(model.snapshot.sessionId, "Nothing plays by itself")

        action.perform()
        let added = try XCTUnwrap(model.libraryItems.first { $0.title == "Play Now Article" })
        XCTAssertEqual(model.snapshot.itemId, added.id)
        XCTAssertEqual(model.screen, .playback)
    }

    /// #784: with something in Now Playing, today's message stays, with no button; and a stale
    /// Play now tapped after something else started does nothing.
    func testAnAddDuringPlaybackKeepsTodaysMessageAndAStalePlayNowDoesNothing() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.importTitle = "First Article"
        model.importText = "The first article, added with nothing playing."
        model.importTextItem(startListening: false)
        let stale = try XCTUnwrap(model.feedbackEvent?.action)

        model.startItem(id: "item-pill")
        model.pause()
        let nowPlaying = model.snapshot
        model.openHome()
        stale.perform()
        XCTAssertEqual(model.snapshot.sessionId, nowPlaying.sessionId, "Play now must not replace what's in Now Playing")
        XCTAssertEqual(model.snapshot.itemId, nowPlaying.itemId)

        model.importTitle = "Second Article"
        model.importText = "The second article, added while another item is paused."
        model.importTextItem(startListening: false)
        XCTAssertEqual(model.feedbackEvent?.message, "Added Second Article to Library without changing Now Playing.")
        XCTAssertNil(model.feedbackEvent?.action)
        XCTAssertEqual(model.snapshot.sessionId, nowPlaying.sessionId)
    }

    /// #1149: marking an item complete is confirmed on the shared top banner with an Undo button. It used
    /// to be a row inside the Library list that pushed every row down.
    func testMarkingCompleteOffersUndoOnTheSharedBannerAndUndoRestoresTheItem() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        let title = try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).title

        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()

        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.kind, .success)
        XCTAssertEqual(event.message, ManualCompletionMessages.completed(title: title))
        let undo = try XCTUnwrap(event.action, "Marking complete must offer Undo")
        XCTAssertEqual(undo.title, "Undo")
        XCTAssertEqual(undo.identifier, "completion.undo.button")
        XCTAssertEqual(undo.accessibilityLabel, ManualCompletionMessages.undoAccessibilityLabel(title: title))
        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).isCompleted)

        undo.perform()
        await model.settleLibraryReload()

        XCTAssertFalse(try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).isCompleted)
        XCTAssertEqual(model.feedbackEvent?.message, ManualCompletionMessages.undone(title: title))
        XCTAssertNil(model.feedbackEvent?.action)
    }

    /// #1149: a second completion replaces the first banner, and the Undo left on screen undoes the newest.
    func testTwoQuickCompletionsLeaveOneBannerWhoseUndoUndoesTheNewest() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.importTitle = "Second Article"
        model.importText = "A second source, so two items can be marked complete in a row."
        model.importTextItem(startListening: false)
        let secondId = try XCTUnwrap(model.libraryItems.first { $0.title == "Second Article" }).id

        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()
        let first = try XCTUnwrap(model.feedbackEvent)
        model.markItemCompleted(id: secondId)
        await model.settleLibraryReload()
        let newest = try XCTUnwrap(model.feedbackEvent)

        XCTAssertNotEqual(first.id, newest.id, "The second completion replaces the first banner")
        XCTAssertEqual(newest.message, ManualCompletionMessages.completed(title: "Second Article"))
        try XCTUnwrap(newest.action).perform()
        await model.settleLibraryReload()

        XCTAssertFalse(try XCTUnwrap(model.libraryItems.first { $0.id == secondId }).isCompleted)
        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).isCompleted,
                      "Undo on the newest banner must leave the earlier completion alone")
    }

    /// #1149: a long title is shortened, so the banner stays a couple of lines beside its Undo button.
    func testALongTitleDoesNotMakeTheCompletionBannerTall() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        let long = "A very long episode title about automating research and the intelligence explosion that might follow"
        model.importTitle = long
        model.importText = "A source with a long title."
        model.importTextItem(startListening: false)
        let id = try XCTUnwrap(model.libraryItems.first { $0.title == long }).id

        model.markItemCompleted(id: id)
        await model.settleLibraryReload()

        let message = try XCTUnwrap(model.feedbackEvent?.message)
        XCTAssertEqual(message, ManualCompletionMessages.completed(title: long))
        XCTAssertLessThan(message.count, long.count, "The banner must not carry the whole title")
        XCTAssertTrue(try XCTUnwrap(model.feedbackEvent?.action?.accessibilityLabel).contains(long),
                      "VoiceOver still names the whole item")
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
            XCTAssertEqual(model.feedbackEvent?.message, "Summary couldn’t finish.")
            XCTAssertEqual(failure.message, "On-device summary failed: \(LocalFoundationModelError.invalidInterjectionSummary.localizedDescription) Tap Retry Summary to try the model again.")
            XCTAssertEqual(model.lastError, failure.message)
            XCTAssertEqual(model.providerProbeStatus, failure.message)
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
            XCTAssertEqual(model.feedbackEvent?.message, "Summary couldn’t finish.")
            let failure = try XCTUnwrap(model.itemFailures.lastFailure(itemId: "item-pill"))
            XCTAssertEqual(failure.message, "On-device summary failed: \(LocalFoundationModelError.invalidInterjectionSummary.localizedDescription) Tap Retry Summary to try the model again.")
            XCTAssertEqual(model.lastError, failure.message)
            XCTAssertEqual(model.providerProbeStatus, failure.message)
            XCTAssertNil(model.itemFailures.lastFailure(itemId: otherItemId))
            XCTAssertEqual(model.feedbackEvent?.retry?.key, "summary")
        }
    }

    /// #430: the summary failure names its listen. On the Timeline it is the banner; back on the Now screen
    /// for that listen it is the tag under the title, still offering the same Retry.
    func testFailedSummaryIsATagUnderTheTitleOnlyOnItsOwnNowScreen() async throws {
        try await withPendingLocalSummary { model, summarizer in
            let sessionId = try XCTUnwrap(model.snapshot.sessionId)
            await summarizer.fail()
            try await waitForSummaryFailure(model)

            XCTAssertEqual(model.feedbackEvent?.origin, FeedbackOrigin(itemId: "item-pill", sessionId: sessionId, work: .summary))
            XCTAssertEqual(model.screen, .timeline)
            XCTAssertNil(model.playbackFeedbackTag, "Off the Now screen the failure keeps the banner")

            model.openPlayback()
            XCTAssertEqual(model.screen, .playback)
            let shown = try XCTUnwrap(model.playbackFeedbackTag)
            XCTAssertEqual(shown.event.id, model.feedbackEvent?.id)
            XCTAssertEqual(shown.tag.text, "Summary couldn’t finish")
            XCTAssertTrue(shown.tag.offersRetry)
            XCTAssertEqual(shown.event.retry?.key, "summary")
            XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message, model.lastError,
                           "The full message stays on the item")
        }
    }

    /// Only the summary and transcription failure paths set an origin; every other event keeps the banner.
    func testAFailureWithoutOriginKeepsTheBannerOnTheNowScreen() {
        // A James or Lily choice left pending on the Terms holds the start, so nothing plays and the
        // Now screen never opens. Choose the iPhone voice, as the other playback tests here do, and put
        // the shared voice preferences back afterwards (#1448).
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.hasActiveSession, "The item must be playing before the Now screen can open")
        model.openPlayback()
        XCTAssertEqual(model.screen, .playback)

        model.reportFailure("Clipboard does not contain text.")

        XCTAssertNil(model.feedbackEvent?.origin)
        XCTAssertNil(model.playbackFeedbackTag)
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
        await model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
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
