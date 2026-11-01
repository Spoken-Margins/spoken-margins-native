import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #1469: keep provider requests independently suspended while the real app switches sessions.
/// The store is a temporary SQLite database; no test touches the listener's Library or an AI service.
@MainActor
final class SummaryFailureOwnershipWorkflowTests: XCTestCase {
    private let originalNote = "ORIGINAL_A: compare this argument with its evidence."
    private let otherNote = "OTHER_TARGET: this is a note on a different generated turn."

    private struct Fixture {
        let model: Gate1AppModel
        let provider: HeldSummaryProvider
        let database: URL
        let a: String
        let b: String
        let noteA: String
        let noteB: String?
    }

    private func fixture(bHasSummary: Bool) async throws -> Fixture {
        let preferences = VoicePreferencesSnapshot.capture()
        let root = FileManager.default.temporaryDirectory.appending(path: "summary-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "library.sqlite")
        let provider = HeldSummaryProvider()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: provider,
            databaseURLOverride: database
        )
        addTeardownBlock { @MainActor in
            await provider.cancelAll()
            model.pause()
            preferences.restore()
            // Detached app readers can still hold SQLite connections here. The lane removes
            // this disposable app container; never unlink a database while it is open.
        }
        model.resetAndSeed()
        model.declineCurrentTerms() // Select the system voice; this test never renders bundled speech.
        let store = try XCTUnwrap(model.store)
        try store.saveItem(Item(id: "summary-b", title: "Summary B", mediaType: "text", text: "A second source.", externalReference: nil, status: "ready"))
        model.startItem(id: "item-pill")
        let a = try XCTUnwrap(model.snapshot.sessionId)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: originalNote)
        await model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        let noteA = try XCTUnwrap(store.loadInterjections(sessionId: a).last?.id)
        XCTAssertTrue(model.canSummarizeInterjections)
        model.summarize()
        try await waitForRequests(1, provider)
        model.startItem(id: "summary-b")
        let b = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(a, b)
        var noteB: String?
        if bHasSummary {
            model.beginWrittenMargin()
            model.saveWrittenMargin(text: "B_ONLY: keep this request pending while A fails.")
            await model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
            noteB = try XCTUnwrap(store.loadInterjections(sessionId: b).last?.id)
            model.summarize()
            try await waitForRequests(2, provider)
        }
        return Fixture(model: model, provider: provider, database: database, a: a, b: b, noteA: noteA, noteB: noteB)
    }

    private func waitForRequests(_ count: Int, _ provider: HeldSummaryProvider) async throws {
        for _ in 0..<500 {
            if await provider.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Provider did not receive \(count) independently held request(s)")
        throw HeldSummaryProvider.Failure.timeout
    }

    private func failA(_ f: Fixture) async throws -> UserFeedbackEvent.Retry {
        let initialRequests = await f.provider.requests
        let aRequest = try XCTUnwrap(initialRequests.first)
        XCTAssertEqual(try summaryNoteIDs(in: aRequest.context), [f.noteA], "The held request must actually belong to A")
        try await f.provider.fail(aRequest.id)
        for _ in 0..<500 {
            if f.model.diagnostics["lastSummaryMode"] == "apple_foundation_failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.model.diagnostics["lastSummaryMode"], "apple_foundation_failed")
        XCTAssertEqual(f.model.snapshot.sessionId, f.b, "A's late failure must leave B selected")
        let reopened = try SQLiteSessionStore(path: f.database.path)
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.a).last?.status, "retryable")
        XCTAssertEqual(try reopened.loadTurns(sessionId: f.a).last?.status, "failed")
        XCTAssertEqual(f.model.itemFailures.lastFailure(itemId: "item-pill")?.message, f.model.lastError)
        XCTAssertNil(f.model.itemFailures.lastFailure(itemId: "summary-b"))
        XCTAssertEqual(f.model.feedbackEvent?.origin, FeedbackOrigin(itemId: "item-pill", sessionId: f.a, work: .summary))
        XCTAssertNil(f.model.playbackFeedbackTag, "A's late failure must not read as a tag on B's Now screen (#430)")
        return try XCTUnwrap(f.model.feedbackEvent?.retry)
    }

    func testLateAFailureLeavesBsIndependentlyHeldSummaryPendingAndRetryReturnsToA() async throws {
        let f = try await fixture(bHasSummary: true)
        let retry = try await failA(f)
        let reopened = try SQLiteSessionStore(path: f.database.path)
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.b).last?.status, "pending")
        XCTAssertEqual(try reopened.loadTurns(sessionId: f.b).last?.status, "pending")
        let pendingCount = await f.provider.pendingCount
        XCTAssertEqual(pendingCount, 1, "B's actual provider continuation stays held")

        f.model.startItem(id: "item-pill")
        retry.action()
        try await waitForRequests(3, f.provider)
        let requests = await f.provider.requests
        let request = try XCTUnwrap(requests.last)
        let retryNoteIDs = try summaryNoteIDs(in: request.context)
        XCTAssertEqual(retryNoteIDs, [f.noteA])
        XCTAssertFalse(retryNoteIDs.contains(try XCTUnwrap(f.noteB)))
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.a).last?.status, "pending")
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.b).last?.status, "pending")
    }

    func testLateAFailureWhenBHasNoSummaryCanRecoverAWithoutCreatingAnyBJob() async throws {
        let f = try await fixture(bHasSummary: false)
        let retry = try await failA(f)
        let reopened = try SQLiteSessionStore(path: f.database.path)
        XCTAssertTrue(try reopened.loadAIJobs(sessionId: f.b).isEmpty)
        XCTAssertTrue(try reopened.loadTurns(sessionId: f.b).isEmpty)
        f.model.startItem(id: "item-pill")
        retry.action()
        try await waitForRequests(2, f.provider)
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.a).last?.status, "pending")
        XCTAssertTrue(try reopened.loadAIJobs(sessionId: f.b).isEmpty)
    }

    func testCapturedRetryDoesNotSummarizeADifferentTargetAfterReturningToA() async throws {
        let f = try await fixture(bHasSummary: false)
        let retry = try await failA(f)
        let failureID = try XCTUnwrap(f.model.feedbackEvent?.id)
        let store = try XCTUnwrap(f.model.store)
        let originalJob = try XCTUnwrap(store.loadAIJobs(sessionId: f.a).last)
        let originalTurn = try XCTUnwrap(store.loadTurns(sessionId: f.a).last)
        let originalTitle = try store.loadItem(id: "item-pill").title
        let originalNoteID = f.noteA
        f.model.startItem(id: "item-pill")
        let turn = ConversationTurn(id: "another-target", sessionId: f.a, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "A different discussion target.", rawText: nil, sourceInterjectionIds: [])
        try store.saveTurn(turn)
        f.model.playTurn(turn)
        XCTAssertEqual(f.model.summaryScopeForCurrentTarget(), SummaryScope(targetType: "turn", turnId: turn.id))
        f.model.beginWrittenMargin()
        f.model.saveWrittenMargin(text: otherNote)
        await f.model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        XCTAssertTrue(f.model.canSummarizeInterjections)
        let otherNoteID = try XCTUnwrap(store.loadInterjections(sessionId: f.a).first { $0.displayText == otherNote }?.id)
        let beforeRequests = await f.provider.requests.count
        let beforeJobs = try store.loadAIJobs(sessionId: f.a)
        let beforeActionFeedbackID = f.model.feedbackEvent?.id

        // The actual banner dismisses itself before invoking its captured action.
        f.model.dismissFeedback(id: failureID)
        retry.action()

        var navigatedToOriginalScope = false
        var refusal: UserFeedbackEvent?
        var performedNavigation: UUID?
        for _ in 0..<500 {
            if await f.provider.requests.count > beforeRequests { break }
            let hasPendingJob = try store.loadAIJobs(sessionId: f.a).contains { $0.status == "pending" || $0.status == "deferred" }
            if !hasPendingJob, f.model.snapshot.sessionId == f.a,
               f.model.summaryScopeForCurrentTarget() == SummaryScope(targetType: "item") {
                navigatedToOriginalScope = true
                break
            }
            if let event = f.model.feedbackEvent, event.id != beforeActionFeedbackID, event.id != failureID {
                if let action = event.action, performedNavigation != event.id {
                    performedNavigation = event.id
                    action.perform()
                }
                if !hasPendingJob, isExplicitOriginalScopeRefusal(event, itemTitle: originalTitle) {
                    refusal = event
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await f.provider.requests
        let added = Array(requests.dropFirst(beforeRequests))
        let submittedNoteIDs = try added.flatMap { try summaryNoteIDs(in: $0.context) }
        XCTAssertFalse(submittedNoteIDs.contains(otherNoteID), "A stale Retry must never silently summarize the different target")
        if !added.isEmpty {
            XCTAssertTrue(submittedNoteIDs.contains(originalNoteID), "A resubmitted request must retain A's original context")
            let pending = try XCTUnwrap(store.loadAIJobs(sessionId: f.a).last { $0.status == "pending" })
            XCTAssertEqual(pending.itemId, "item-pill")
            let pendingTurn = try XCTUnwrap(store.loadTurns(sessionId: f.a).first { $0.id == pending.turnId })
            XCTAssertTrue(pendingTurn.sourceInterjectionIds.contains(originalNoteID))
            XCTAssertFalse(pendingTurn.sourceInterjectionIds.contains(otherNoteID))
        } else {
            // A truthful refusal or actual navigation is equally valid; a silent no-op is not.
            XCTAssertTrue(navigatedToOriginalScope || refusal != nil, "Retry must visibly return to the original item scope or explain why original-scope recovery cannot proceed")
            XCTAssertEqual(try store.loadAIJobs(sessionId: f.a), beforeJobs)
            XCTAssertEqual(try store.loadAIJobs(sessionId: f.a).first { $0.id == originalJob.id }?.status, "retryable")
            XCTAssertEqual(try store.loadTurns(sessionId: f.a).first { $0.id == originalTurn.id }?.status, "failed")
        }
        XCTAssertTrue(try store.loadAIJobs(sessionId: f.b).isEmpty)
        XCTAssertTrue(try store.loadTurns(sessionId: f.b).isEmpty)
    }

    func testRetryWhileBIsActiveRefusesWithoutChangingEitherSessionsJobs() async throws {
        let f = try await fixture(bHasSummary: true)
        let retry = try await failA(f)
        let store = try XCTUnwrap(f.model.store)
        let jobsA = try store.loadAIJobs(sessionId: f.a)
        let jobsB = try store.loadAIJobs(sessionId: f.b)
        let requestCount = await f.provider.requests.count
        if let event = f.model.feedbackEvent { f.model.dismissFeedback(id: event.id) }
        retry.action()
        XCTAssertEqual(f.model.snapshot.sessionId, f.b)
        XCTAssertEqual(try store.loadAIJobs(sessionId: f.a), jobsA)
        XCTAssertEqual(try store.loadAIJobs(sessionId: f.b), jobsB)
        let afterRequests = await f.provider.requests.count
        XCTAssertEqual(afterRequests, requestCount)
        XCTAssertTrue(isExplicitOriginalScopeRefusal(try XCTUnwrap(f.model.feedbackEvent), itemTitle: try store.loadItem(id: "item-pill").title))
    }

    func testRetryUsesTheOriginalRequestWhenAnotherMarginWasAddedToTheSameTarget() async throws {
        let f = try await fixture(bHasSummary: false)
        let retry = try await failA(f)
        let store = try XCTUnwrap(f.model.store)
        let originalJob = try XCTUnwrap(store.loadAIJobs(sessionId: f.a).last)
        f.model.startItem(id: "item-pill")
        let beforeNotes = try store.loadInterjections(sessionId: f.a)
        let beforeIDs = Set(beforeNotes.map(\.id))
        let newText = "NEW_NOTE: do not silently add this to an old Retry."
        f.model.beginWrittenMargin()
        f.model.saveWrittenMargin(text: newText)
        await f.model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        let afterNotes = try store.loadInterjections(sessionId: f.a)
        // SQLite orders by second-resolution updated_at, then ID. A tied timestamp
        // can put the original UUID last; enumeration order is not creation order.
        XCTAssertEqual(afterNotes.count, beforeNotes.count + 1, "Saving must actually add a new Margin")
        XCTAssertEqual(Set(afterNotes.map(\.id)).count, afterNotes.count)
        let addedNotes = afterNotes.filter { !beforeIDs.contains($0.id) }
        XCTAssertEqual(addedNotes.count, 1, "Identify the new saved record, never the last enumerated row")
        let newNote = try XCTUnwrap(addedNotes.first)
        XCTAssertEqual(newNote.transcript, newText)
        XCTAssertEqual(newNote.sessionId, f.a)
        XCTAssertEqual(newNote.itemId, "item-pill")
        XCTAssertEqual(newNote.targetType, .item)
        XCTAssertEqual(newNote.targetId, "item-pill")
        XCTAssertEqual(newNote.status, "active")
        XCTAssertNotEqual(newNote.id, f.noteA)
        // Playback's explicit Retry Summary button, tapped while the records still hold an older state's answer (no jobs): the tap itself
        // must wait for this state's read rather than refuse from the stale answer (#2747).
        f.model.retryPendingAI()
        try await waitForRequests(2, f.provider)
        let requests = await f.provider.requests
        let retriedIDs = try summaryNoteIDs(in: XCTUnwrap(requests.last).context)
        XCTAssertEqual(retriedIDs, [f.noteA])
        XCTAssertFalse(retriedIDs.contains(newNote.id), "Retry must exclude the newly saved Margin")
        let jobs = try store.loadAIJobs(sessionId: f.a)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.last?.id, originalJob.id)
        XCTAssertEqual(jobs.last?.status, "pending")
        XCTAssertEqual(try store.loadTurns(sessionId: f.a).first { $0.id == originalJob.turnId }?.sourceInterjectionIds, [f.noteA])

        // A retained callback cannot submit the same pending job twice.
        retry.action()
        let repeatedRequests = await f.provider.requests.count
        XCTAssertEqual(repeatedRequests, 2)
        XCTAssertEqual(try store.loadAIJobs(sessionId: f.a), jobs)
    }

    func testRetryWithDeletedOriginalMarginRefusesWithoutRecreatingItsJob() async throws {
        let f = try await fixture(bHasSummary: false)
        let retry = try await failA(f)
        let store = try XCTUnwrap(f.model.store)
        f.model.startItem(id: "item-pill")
        var original = try XCTUnwrap(store.loadInterjections(sessionId: f.a).first { $0.id == f.noteA })
        original.status = "deleted"
        try store.saveInterjection(original)
        let jobs = try store.loadAIJobs(sessionId: f.a)
        let turns = try store.loadTurns(sessionId: f.a)
        if let event = f.model.feedbackEvent { f.model.dismissFeedback(id: event.id) }
        retry.action()
        XCTAssertEqual(try store.loadAIJobs(sessionId: f.a), jobs)
        XCTAssertEqual(try store.loadTurns(sessionId: f.a), turns)
        let requestCount = await f.provider.requests.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(isExplicitOriginalScopeRefusal(try XCTUnwrap(f.model.feedbackEvent), itemTitle: try store.loadItem(id: "item-pill").title))
        f.model.beginWrittenMargin()
        f.model.saveWrittenMargin(text: "NEW_AFTER_DELETE: a fresh summary remains possible.")
        await f.model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        let newNote = try XCTUnwrap(store.loadInterjections(sessionId: f.a).last { $0.status == "active" }?.id)
        // The controls answer from records read off the main thread (#2508); ask once they are read for this state.
        await f.model.settleSummaryRecords()
        XCTAssertFalse(f.model.canRetryLocalSummary)
        XCTAssertEqual(f.model.summaryActionTitle, "Summarize Notes")
        f.model.summarize()
        try await waitForRequests(2, f.provider)
        let requests = await f.provider.requests
        XCTAssertEqual(try summaryNoteIDs(in: XCTUnwrap(requests.last).context), [newNote])
    }

    func testTimelineOffersANewSummaryForAnotherTargetAfterTheOriginalFailed() async throws {
        try await assertVisibleRetryRefusesOtherTarget(useTimelineAction: true)
    }

    func testPlaybackRetryButtonDoesNotSummarizeAnotherTarget() async throws {
        try await assertVisibleRetryRefusesOtherTarget(useTimelineAction: false)
    }

    private func assertVisibleRetryRefusesOtherTarget(useTimelineAction: Bool) async throws {
        let f = try await fixture(bHasSummary: false)
        _ = try await failA(f)
        let store = try XCTUnwrap(f.model.store)
        f.model.startItem(id: "item-pill")
        let other = ConversationTurn(id: "visible-retry-other", sessionId: f.a, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Another discussion.", rawText: nil, sourceInterjectionIds: [])
        try store.saveTurn(other)
        f.model.playTurn(other)
        f.model.beginWrittenMargin()
        f.model.saveWrittenMargin(text: otherNote)
        await f.model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        // The controls answer from records read off the main thread (#2508); ask once they are read for this state.
        await f.model.settleSummaryRecords()
        XCTAssertFalse(f.model.canRetryLocalSummary, "Another target's failure must not label this action Retry")
        XCTAssertEqual(f.model.summaryActionTitle, "Summarize Notes")
        let beforeJobs = try store.loadAIJobs(sessionId: f.a)
        if let event = f.model.feedbackEvent { f.model.dismissFeedback(id: event.id) }
        if useTimelineAction {
            let otherID = try XCTUnwrap(store.loadInterjections(sessionId: f.a).first { $0.targetId == other.id }?.id)
            f.model.summarize() // Timeline now truthfully offers a new Summarize action.
            try await waitForRequests(2, f.provider)
            let requests = await f.provider.requests
            XCTAssertEqual(try summaryNoteIDs(in: XCTUnwrap(requests.last).context), [otherID])
            XCTAssertEqual(try store.loadAIJobs(sessionId: f.a).first { $0.id == beforeJobs.first?.id }?.status, "retryable")
        } else {
            // Settled, the tap decides at once, so the refusal and the unchanged jobs can be checked right after it.
            await f.model.settleSummaryRecords()
            f.model.retryPendingAI() // A stale explicit Retry action still must refuse.
            XCTAssertEqual(try store.loadAIJobs(sessionId: f.a), beforeJobs)
            let requestCount = await f.provider.requests.count
            XCTAssertEqual(requestCount, 1)
            XCTAssertTrue(isExplicitOriginalScopeRefusal(try XCTUnwrap(f.model.feedbackEvent), itemTitle: try store.loadItem(id: "item-pill").title))
        }
    }

    func testRetryAfterModelReloadUsesOnlyTheFailedTurnsPersistedSourceIDs() async throws {
        let f = try await fixture(bHasSummary: false)
        _ = try await failA(f)
        f.model.pause()
        let provider = HeldSummaryProvider()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: provider,
            databaseURLOverride: f.database
        )
        addTeardownBlock { @MainActor in
            await provider.cancelAll()
            model.pause()
        }
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.sessionId, f.a)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "AFTER_RELOAD: this new note was not in the failed summary.")
        await model.settleItemReload() // the item detail reloads off the main thread after a save (#2505)
        // A reloaded model has read no summary records yet (#2508); the label is right once they are read.
        await model.settleSummaryRecords()
        XCTAssertTrue(model.canRetryLocalSummary)
        model.retryPendingAI()
        try await waitForRequests(1, provider)
        let requests = await provider.requests
        XCTAssertEqual(try summaryNoteIDs(in: XCTUnwrap(requests.first).context), [f.noteA])
        let reopened = try SQLiteSessionStore(path: f.database.path)
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: f.a).count, 1)
        XCTAssertEqual(try reopened.loadTurns(sessionId: f.a).first { $0.turnType == "interjection_summary" }?.sourceInterjectionIds, [f.noteA])
    }

    /// Request identity is in JSON IDs. The production note cleaner intentionally removes
    /// final punctuation, so searching for the whole original sentence is a false premise.
    private func summaryNoteIDs(in context: String) throws -> [String] {
        try JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: Data(context.utf8))
            .interjections.map(\.id)
    }

    private func isExplicitOriginalScopeRefusal(_ event: UserFeedbackEvent, itemTitle: String) -> Bool {
        guard event.kind == .error else { return false }
        let message = event.message.lowercased()
        let namesOriginal = message.contains("original") || message.contains(itemTitle.lowercased())
        let explainsRecovery = ["changed", "unavailable", "return", "open", "cannot", "can't", "could not"].contains { message.contains($0) }
        return namesOriginal && explainsRecovery
    }

}

private actor HeldSummaryProvider: LocalFoundationModelClient {
    struct Request: Sendable { let id: Int; let context: String }
    enum Failure: Error { case controlled, timeout, missingRequest }
    private(set) var requests: [Request] = []
    private var held: [Int: CheckedContinuation<String, Error>] = [:]
    var pendingCount: Int { held.count }

    nonisolated func availability() -> LocalFoundationModelAvailability { .available }
    func summarizeInterjections(context: String) async throws -> String {
        let id = requests.count
        requests.append(Request(id: id, context: context))
        return try await withCheckedThrowingContinuation { held[id] = $0 }
    }
    func fail(_ id: Int) throws {
        guard let request = held.removeValue(forKey: id) else { throw Failure.missingRequest }
        request.resume(throwing: Failure.controlled)
    }
    func cancelAll() {
        let pending = held.values
        held.removeAll()
        for request in pending { request.resume(throwing: CancellationError()) }
    }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel { throw Failure.controlled }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String { throw Failure.controlled }
}
