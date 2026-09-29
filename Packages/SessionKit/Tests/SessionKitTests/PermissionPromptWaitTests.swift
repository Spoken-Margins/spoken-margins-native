import XCTest
@testable import SessionKit

/// #217: tapping Allow more than 10 seconds after the microphone prompt appeared was reported as
/// denied, and the listener was sent to Settings for a permission they had just granted.
final class PermissionPromptWaitTests: XCTestCase {
    /// A prompt the test answers: `status` changes when the listener taps, and `request` returns then.
    private final class Prompt: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        var status: PermissionPromptStatus {
            lock.withLock { answer.map { $0 ? .granted : .denied } ?? .undetermined }
        }

        func request() async -> Bool {
            await withCheckedContinuation { continuation in
                let ready: Bool? = lock.withLock {
                    if let answer { return answer }
                    waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        func tap(_ allow: Bool) {
            let pending = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                answer = allow
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in pending { waiter.resume(returning: allow) }
        }
    }

    private let timeout = Duration.milliseconds(20)

    func testAllowTappedLongAfterTheTimeoutIsStillAYes() async {
        let prompt = Prompt()
        Task {
            try? await Task.sleep(for: .milliseconds(200)) // ten timeouts later
            prompt.tap(true)
        }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await prompt.request() },
            currentStatus: { prompt.status },
            timeout: timeout
        )
        XCTAssertTrue(granted, "a slow Allow is a yes")
    }

    func testDontAllowIsANo() async {
        let prompt = Prompt()
        Task { try? await Task.sleep(for: .milliseconds(60)); prompt.tap(false) }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await prompt.request() },
            currentStatus: { prompt.status },
            timeout: timeout
        )
        XCTAssertFalse(granted)
    }

    func testARequestThatNeverReportsBackEndsOnceIOSHasDecided() async {
        // The original guard: the request hangs, but iOS has already recorded a yes.
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in } },
            currentStatus: { .granted },
            timeout: timeout
        )
        XCTAssertTrue(granted)
        let denied = await PermissionPromptWait.awaitAnswer(
            request: { await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in } },
            currentStatus: { .denied },
            timeout: timeout
        )
        XCTAssertFalse(denied)
    }

    func testAnAnswerBeforeTheTimeoutIsReturnedAtOnce() async {
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { true },
            currentStatus: { .undetermined },
            timeout: .seconds(60)
        )
        XCTAssertTrue(granted)
    }
}
