import XCTest
@testable import SessionKit

/// #2183: after another app's audio ended with "should resume", the resume's session activation failed once and the
/// app gave up, so publisher audio stayed paused in the background until the listener pressed play.
@MainActor
final class InterruptionResumeRetrierTests: XCTestCase {
    private struct ActivationFailed: Error, LocalizedError {
        var errorDescription: String? { "Session activation failed" }
    }

    private final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ ms: Int) { lock.lock(); values.append(ms); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func make(delays: [Int] = [10, 20, 40], waits: Waits = Waits()) -> InterruptionResumeRetrier {
        InterruptionResumeRetrier(delaysMs: delays, sleep: { waits.add($0) })
    }

    func testAnActivationThatFailsOnceThenSucceedsResumesOnTheFirstRetry() async {
        let waits = Waits()
        let retrier = make(waits: waits)
        var attempts = 0
        var outcomes: [InterruptionResumeRetrier.Outcome] = []

        retrier.begin(
            after: ActivationFailed(),
            stillWaiting: { true },
            attempt: { attempts += 1 },
            report: { outcomes.append($0) }
        )
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(outcomes, [.resumed(attempt: 1)])
        XCTAssertEqual(waits.all, [10])
        XCTAssertFalse(retrier.isRetrying)
    }

    func testARefusalEveryTimeGivesUpAfterTheBoundWithTheReason() async {
        let retrier = make()
        var attempts = 0
        var outcomes: [InterruptionResumeRetrier.Outcome] = []

        retrier.begin(
            after: ActivationFailed(),
            stillWaiting: { true },
            attempt: { attempts += 1; throw ActivationFailed() },
            report: { outcomes.append($0) }
        )
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 3, "one attempt per delay and no more")
        guard case .gaveUp(let count, let why)? = outcomes.last else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(why.hasPrefix("Session activation failed ("), why)
        XCTAssertEqual(outcomes.count, 3, "two failed retries reported, then the give-up")
    }

    func testTheListenerTakingOverStopsTheRetries() async {
        let retrier = make()
        var attempts = 0
        var outcomes: [InterruptionResumeRetrier.Outcome] = []

        retrier.begin(
            after: ActivationFailed(),
            stillWaiting: { false }, // the listener pressed play or opened another item
            attempt: { attempts += 1 },
            report: { outcomes.append($0) }
        )
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(outcomes, [.abandoned(attempts: 0)])
    }

    func testCancelStopsARetryThatIsWaiting() async {
        let gate = AsyncGate()
        let retrier = InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in await gate.wait() })
        var attempts = 0

        retrier.begin(after: ActivationFailed(), stillWaiting: { true }, attempt: { attempts += 1 }, report: { _ in })
        XCTAssertTrue(retrier.isRetrying)
        retrier.cancel()
        await gate.open()
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(retrier.isRetrying)
    }

    /// The audit's scenario on d37a80e: the app is suspended with a 4 s sleep pending, and the sleep is long over
    /// when it next runs. The continuous clock has moved on by hours, so the retry must not start playback.
    func testARetryThatWakesAfterTheWindowDoesNotResume() async {
        let clock = Clock()
        let retrier = InterruptionResumeRetrier(
            delaysMs: [1_000, 2_000],
            sleep: { _ in clock.advance(milliseconds: 6 * 3_600_000) }, // suspended overnight
            now: { clock.now }
        )
        var attempts = 0
        var outcomes: [InterruptionResumeRetrier.Outcome] = []

        retrier.begin(
            after: ActivationFailed(),
            stillWaiting: { true },
            attempt: { attempts += 1 },
            report: { outcomes.append($0) }
        )
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 0, "a resume hours after the interruption would play with no one asking")
        XCTAssertEqual(outcomes, [.abandoned(attempts: 0)])
    }

    func testRetriesInsideTheWindowStillRunWhenTheClockMovesWithTheDelays() async {
        let clock = Clock()
        let retrier = InterruptionResumeRetrier(
            delaysMs: [1_000, 2_000, 4_000],
            sleep: { clock.advance(milliseconds: $0 + 100) }, // each wait runs a little long
            now: { clock.now }
        )
        var attempts = 0
        var outcomes: [InterruptionResumeRetrier.Outcome] = []

        retrier.begin(
            after: ActivationFailed(),
            stillWaiting: { true },
            attempt: { attempts += 1; if attempts < 3 { throw ActivationFailed() } },
            report: { outcomes.append($0) }
        )
        await retrier.waitUntilIdle()

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(outcomes.last, .resumed(attempt: 3))
    }

    func testTheDescriptionCarriesTheDomainAndCode() {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 561_015_905, userInfo: [NSLocalizedDescriptionKey: "Session activation failed"])

        XCTAssertEqual(InterruptionResumeRetrier.describe(error), "Session activation failed (com.apple.coreaudio.avfaudio 561015905)")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(milliseconds: Int) { lock.lock(); instant = instant + .milliseconds(milliseconds); lock.unlock() }
    }

    /// A sleep that returns when released, so a test can cancel while the retry waits.
    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
