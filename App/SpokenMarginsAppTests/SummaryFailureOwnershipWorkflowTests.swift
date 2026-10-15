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
    }

    private func fixture(bHasSummary: Bool) async throws -> Fixture {
        let preferences = VoicePreferencesSnapshot.capture()
        let root = FileManager.default.temporaryDirectory.appending(path: "summary-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "library.sqlite")
        let provider = HeldSummaryProvider()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: provider,
            databaseURLOverride: database
        )
        addTeardownBlock { @MainActor in
            await provider.cancelAll()
            model.pause()
            preferences.restore()
            try? FileManager.default.removeItem(at: root)
        }
        model.resetAndSeed()
        model.declineCurrentTerms() // Select the system voice; this test never renders bundled speech.
        let store = try XCTUnwrap(model.store)
        try store.saveItem(Item(id: "summary-b", title: "Summary B", mediaType: "text", text: "A second source.", externalReference: nil, status: "ready"))
        model.startItem(id: "item-pill")
        let a = try XCTUnwrap(model.snapshot.sessionId)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: originalNote)
        XCTAssertTrue(model.canSummarizeInterjections)
        model.summarize()
        try await waitForRequests(1, provider)
        model.startItem(id: "summary-b")
        let b = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(a, b)
        if bHasSummary {
            model.beginWrittenMargin()
            model.saveWrittenMargin(text: "B_ONLY: keep this request pending while A fails.")
            model.summarize()
            try await waitForRequests(2, provider)
        }
        return Fixture(model: model, provider: provider, database: database, a: a, b: b)
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
        XCTAssertTrue(aRequest.context.contains(originalNote), "The held request must actually belong to A")
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
        XCTAssertTrue(request.context.contains(originalNote))
        XCTAssertFalse(request.context.contains("B_ONLY"))
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
        let originalNoteID = try XCTUnwrap(store.loadInterjections(sessionId: f.a).first?.id)
        f.model.startItem(id: "item-pill")
        let turn = ConversationTurn(id: "another-target", sessionId: f.a, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "A different discussion target.", rawText: nil, sourceInterjectionIds: [])
        try store.saveTurn(turn)
        f.model.playTurn(turn)
        XCTAssertEqual(f.model.summaryScopeForCurrentTarget(), SummaryScope(targetType: "turn", turnId: turn.id))
        f.model.beginWrittenMargin()
        f.model.saveWrittenMargin(text: otherNote)
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
        XCTAssertFalse(added.contains { $0.context.contains(otherNote) }, "A stale Retry must never silently summarize the different target")
        if !added.isEmpty {
            XCTAssertTrue(added.contains { $0.context.contains(originalNote) }, "A resubmitted request must retain A's original context")
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
