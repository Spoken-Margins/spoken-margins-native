import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// A successful provider response must settle its originating request, just like
/// a failure. This uses actual app submission and persistence, not engine stubs.
@MainActor
final class SummarySuccessOwnershipWorkflowTests: XCTestCase {
    func testLateASuccessLeavesBsIndependentlyHeldSummaryUntouched() async throws {
        try await qualifyLateSuccess(bHasSummary: true)
    }

    func testLateASuccessDoesNotCreateATurnInBWhenBHasNoSummary() async throws {
        try await qualifyLateSuccess(bHasSummary: false)
    }

    private func qualifyLateSuccess(bHasSummary: Bool) async throws {
        let preferences = VoicePreferencesSnapshot.capture()
        let directory = FileManager.default.temporaryDirectory.appending(path: "summary-success-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "library.sqlite")
        let provider = HeldSummarySuccessProvider()
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
            // App readers can outlive this method; the isolated lane container
            // owns cleanup, not an unlink of a database with live connections.
        }
        model.resetAndSeed()
        model.declineCurrentTerms()
        let store = try XCTUnwrap(model.store)
        try store.saveItem(Item(id: "success-b", title: "Success B", mediaType: "text", text: "A second source.", externalReference: nil, status: "ready"))
        model.startItem(id: "item-pill")
        let a = try XCTUnwrap(model.snapshot.sessionId)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "A_ORIGINAL_NOTE: compare this argument with its evidence.")
        let noteA = try XCTUnwrap(store.loadInterjections(sessionId: a).last?.id)
        model.summarize()
        try await waitForRequests(1, provider: provider)
        let jobA = try XCTUnwrap(store.loadAIJobs(sessionId: a).last)
        let turnA = try XCTUnwrap(store.loadTurns(sessionId: a).last)
        XCTAssertEqual(turnA.sourceInterjectionIds, [noteA])
        let initialRequests = await provider.requests
        let requestA = try XCTUnwrap(initialRequests.first)
        XCTAssertEqual(try noteIDs(requestA.context), [noteA])

        model.startItem(id: "success-b")
        let b = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(a, b)
        if bHasSummary {
            model.beginWrittenMargin()
            model.saveWrittenMargin(text: "B_ONLY_NOTE: this request must remain independently pending.")
            let noteB = try XCTUnwrap(store.loadInterjections(sessionId: b).last?.id)
            model.summarize()
            try await waitForRequests(2, provider: provider)
            let requests = await provider.requests
            XCTAssertEqual(try noteIDs(XCTUnwrap(requests.last).context), [noteB])
        }
        let jobsB = try store.loadAIJobs(sessionId: b)
        let turnsB = try store.loadTurns(sessionId: b)
        let targetB = model.snapshot.targetId
        if bHasSummary {
            XCTAssertEqual(jobsB.last?.status, "pending")
            XCTAssertEqual(turnsB.last?.status, "pending")
        } else {
            XCTAssertTrue(jobsB.isEmpty)
            XCTAssertTrue(turnsB.isEmpty)
        }

        let responseA = "SUMMARY_A_ONLY: Compare the original argument with its evidence. Keep this result with source A."
        try await provider.succeed(requestA.id, text: responseA)
        for _ in 0..<500 {
            if model.diagnostics["lastSummaryMode"] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.diagnostics["lastSummaryMode"], "apple_foundation_on_device", "The real app must finish handling this success before checking storage")
        let reopened = try SQLiteSessionStore(path: database.path)
        let finalJobA = try XCTUnwrap(reopened.loadAIJobs(sessionId: a).first { $0.id == jobA.id })
        let finalTurnA = try XCTUnwrap(reopened.loadTurns(sessionId: a).first { $0.id == turnA.id })
        XCTAssertEqual(finalJobA.status, "complete", "A's successful request must complete A's job")
        XCTAssertEqual(finalTurnA.status, "complete")
        XCTAssertTrue((finalTurnA.rawText ?? finalTurnA.text ?? "").contains("SUMMARY_A_ONLY"))
        XCTAssertEqual(finalTurnA.sourceInterjectionIds, [noteA])
        XCTAssertEqual(try reopened.loadAIJobs(sessionId: b), jobsB, "A's success must not settle B's pending job")
        XCTAssertEqual(try reopened.loadTurns(sessionId: b), turnsB, "A's content must not be written into B")
        XCTAssertEqual(model.snapshot.sessionId, b)
        XCTAssertEqual(model.snapshot.itemId, "success-b")
        XCTAssertEqual(model.snapshot.targetId, targetB)
        let pendingCount = await provider.pendingCount
        XCTAssertEqual(pendingCount, bHasSummary ? 1 : 0, "B's real provider request stays held")
    }

    private func waitForRequests(_ count: Int, provider: HeldSummarySuccessProvider) async throws {
        for _ in 0..<500 {
            if await provider.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The provider did not receive \(count) independent requests")
        throw HeldSummarySuccessProvider.Failure.timeout
    }

    private func noteIDs(_ context: String) throws -> [String] {
        try JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: Data(context.utf8)).interjections.map(\.id)
    }
}

private actor HeldSummarySuccessProvider: LocalFoundationModelClient {
    struct Request: Sendable { let id: Int; let context: String }
    enum Failure: Error { case timeout, missingRequest, unused }
    private(set) var requests: [Request] = []
    private var held: [Int: CheckedContinuation<String, Error>] = [:]
    var pendingCount: Int { held.count }
    nonisolated func availability() -> LocalFoundationModelAvailability { .available }
    func summarizeInterjections(context: String) async throws -> String {
        let id = requests.count
        requests.append(Request(id: id, context: context))
        return try await withCheckedThrowingContinuation { held[id] = $0 }
    }
    func succeed(_ id: Int, text: String) throws {
        guard let request = held.removeValue(forKey: id) else { throw Failure.missingRequest }
        request.resume(returning: text)
    }
    func cancelAll() {
        let pending = held.values
        held.removeAll()
        for request in pending { request.resume(throwing: CancellationError()) }
    }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel { throw Failure.unused }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String { throw Failure.unused }
}
