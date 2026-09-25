import Foundation
import XCTest
@testable import SessionKitAudio

private actor SpeechTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor SpeechTestEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor
final class SpeechRecognitionQueueTests: XCTestCase {
    private enum Failure: Error { case service }

    private func waitForQueue(_ queue: SpeechRecognitionQueue, count: Int) async throws {
        for _ in 0..<500 {
            if await queue.waitingCount == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Request did not enter the recognition queue")
        throw Failure.service
    }

    func testSourceWindowsYieldToOtherItemsAndCancellationDoesNotLeakLease() async throws {
        let queue = SpeechRecognitionQueue()
        let gate = SpeechTestGate()
        let started = SpeechTestGate()
        let events = SpeechTestEvents()
        let first = Task {
            try await queue.run {
                await events.append("first")
                await started.release()
                await gate.wait()
            }
        }
        await started.wait()
        let cancelled = Task { try await queue.run { await events.append("cancelled") } }
        try await waitForQueue(queue, count: 1)
        let otherItem = Task { try await queue.run { await events.append("other-item") } }
        try await waitForQueue(queue, count: 2)
        let nextWindow = Task { try await queue.run { await events.append("next-window") } }
        try await waitForQueue(queue, count: 3)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled request ran") }
        catch is CancellationError { }
        await gate.release()
        try await first.value
        try await otherItem.value
        try await nextWindow.value
        let recorded = await events.values
        XCTAssertEqual(recorded, ["first", "other-item", "next-window"])
    }

    func testSourceFallbackIsStickyAndServiceFailureSuspendsOtherItemsUntilExplicitRetry() async throws {
        let queue = SpeechRecognitionQueue()
        let events = SpeechTestEvents()
        let first: String = try await queue.run {
            try await queue.recognizeSource(preferred: {
                await events.append("preferred-failed")
                throw Failure.service
            }, legacy: { "legacy-result" })
        }
        XCTAssertEqual(first, "legacy-result")
        do {
            let _: String = try await queue.run {
                try await queue.recognizeSource(preferred: {
                    await events.append("preferred-repeated")
                    return "wrong"
                }, legacy: { throw Failure.service })
            }
            XCTFail("Service failure should suspend source recognition")
        } catch { XCTAssertEqual(error as? SourceSpeechRecognitionFailure, .serviceUnavailable) }
        do {
            let _: String = try await queue.run {
                try await queue.recognizeSource(preferred: nil, legacy: {
                    await events.append("suspended-service-repeated")
                    return "wrong"
                })
            }
            XCTFail("Another item must respect the same suspension")
        } catch { XCTAssertEqual(error as? SourceSpeechRecognitionFailure, .serviceUnavailable) }
        try await queue.resetSourceRecognitionAfterExplicitRetry()
        let retried: String = try await queue.run {
            try await queue.recognizeSource(preferred: { "recovered" }, legacy: { "legacy" })
        }
        XCTAssertEqual(retried, "recovered")
        let recorded = await events.values
        XCTAssertEqual(recorded, ["preferred-failed"])
    }

    func testInputFailureAndCancellationDoNotPoisonTheSpeechService() async throws {
        let queue = SpeechRecognitionQueue()
        let failures: [any Error] = [SourceSpeechRecognitionFailure.emptyWindow, CancellationError()]
        for failure in failures {
            do {
                let _: String = try await queue.run {
                    try await queue.recognizeSource(preferred: { throw failure }, legacy: { "wrong" })
                }
                XCTFail("Non-service failure should be preserved")
            } catch { }
        }
        let value: String = try await queue.run {
            try await queue.recognizeSource(preferred: { "preferred-still-available" }, legacy: { "wrong" })
        }
        XCTAssertEqual(value, "preferred-still-available")
    }
}
