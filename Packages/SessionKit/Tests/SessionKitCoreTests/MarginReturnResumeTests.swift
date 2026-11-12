import XCTest
@testable import SessionKit

/// #4110: a friend's Margin ended with the screen locked, the engine's resume threw once, the app showed a banner and
/// never tried again, and the episode stayed paused and silent. The engine here throws on demand.
@MainActor
final class MarginReturnResumeTests: XCTestCase {
    /// The message names a file and a title: a diagnostics line must never carry it.
    private struct SessionRefused: Error, LocalizedError {
        var errorDescription: String? { "Could not start \"Secret Title.mp3\" in /private/var/mobile/Secret" }
    }

    private struct Recorded: Equatable {
        let kind: String
        let fields: [String: String]
    }

    private func make() -> MarginReturnResume {
        MarginReturnResume(retrier: InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in }))
    }

    /// Runs one return and waits for any retry. `failures` is how many leading attempts throw.
    private func run(
        failures: Int,
        inBackground: Bool,
        stillWaiting: Bool = true,
        resumer: MarginReturnResume? = nil
    ) async -> (attempts: Int, outcomes: [MarginReturnResume.Outcome], recorded: [Recorded]) {
        let resumer = resumer ?? make()
        var attempts = 0
        var outcomes: [MarginReturnResume.Outcome] = []
        var recorded: [Recorded] = []
        resumer.resume(
            appIsInBackground: inBackground,
            stillWaiting: { stillWaiting },
            attempt: {
                attempts += 1
                if attempts <= failures { throw SessionRefused() }
            },
            record: { recorded.append(Recorded(kind: $0, fields: $1)) },
            finished: { outcomes.append($0) }
        )
        await resumer.waitUntilIdle()
        return (attempts, outcomes, recorded)
    }

    func testAResumeThatWorksIsOneAttemptAndNoEvent() async {
        let result = await run(failures: 0, inBackground: true)

        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.outcomes, [.resumed])
        XCTAssertEqual(result.recorded, [])
    }

    /// The owner's case. Without the retry this is one attempt, `needsListener`, and a silent paused episode.
    func testABackgroundResumeThatFailsOnceIsRetriedAndResumes() async {
        let result = await run(failures: 1, inBackground: true)

        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.outcomes, [.resumedOnRetry])
        XCTAssertEqual(result.recorded.map(\.kind), [MarginReturnResume.failedKind, MarginReturnResume.retriedKind])
        XCTAssertEqual(result.recorded.first?.fields["willRetry"], "true")
        XCTAssertEqual(result.recorded.last?.fields["outcome"], "resumed")
    }

    func testABackgroundResumeThatKeepsFailingOffersTheListenerAResumeAfterOneRetry() async {
        let result = await run(failures: 5, inBackground: true)

        XCTAssertEqual(result.attempts, 2, "one retry and no more")
        XCTAssertEqual(result.outcomes, [.needsListener(reason: "other#1", retried: true)])
        XCTAssertEqual(result.recorded.last?.fields["outcome"], "gave_up")
    }

    func testAForegroundFailureIsNotRetriedAndOffersTheListenerAResume() async {
        let result = await run(failures: 1, inBackground: false)

        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.outcomes, [.needsListener(reason: "other#1", retried: false)])
        XCTAssertEqual(result.recorded.map(\.kind), [MarginReturnResume.failedKind])
        XCTAssertEqual(result.recorded.first?.fields["appState"], "foreground")
        XCTAssertEqual(result.recorded.first?.fields["willRetry"], "false")
    }

    func testTheListenerTakingOverBeforeTheRetryStopsIt() async {
        let result = await run(failures: 1, inBackground: true, stillWaiting: false)

        XCTAssertEqual(result.attempts, 1, "the retry must not start playback over a listener who moved on")
        XCTAssertEqual(result.outcomes, [.abandoned])
        XCTAssertEqual(result.recorded.last?.fields["outcome"], "abandoned")
    }

    func testANewReturnReplacesARetryStillWaiting() async {
        let first = MarginReturnResume(retrier: InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in await Task.yield() }))
        var firstAttempts = 0
        first.resume(
            appIsInBackground: true, stillWaiting: { true },
            attempt: { firstAttempts += 1; throw SessionRefused() }, record: { _, _ in }, finished: { _ in }
        )
        XCTAssertTrue(first.isRetrying)
        first.cancel()
        await first.waitUntilIdle()

        XCTAssertEqual(firstAttempts, 1)
        XCTAssertFalse(first.isRetrying)
    }

    func testTheFailureEventNamesTheTypeAndCodeAndNeverTheMessage() async {
        let result = await run(failures: 1, inBackground: true)
        let fields = result.recorded.first?.fields ?? [:]

        XCTAssertEqual(fields["errorType"], "SessionRefused", "\(fields)")
        XCTAssertEqual(fields["error"], "other#1")
        XCTAssertEqual(fields["textClass"], "plain")
        for value in result.recorded.flatMap({ $0.fields.values }) {
            XCTAssertFalse(value.contains("Secret"), "diagnostics must not carry the message: \(value)")
            XCTAssertFalse(value.contains("/private"), value)
        }
    }

    func testFailureFieldsForNeighbouringErrors() {
        struct Dump: Error, LocalizedError { var errorDescription: String? { "persistence_failed:disk" } }
        enum Coded: Error { case sessionActivationFailed }
        let cases: [(name: String, error: Error, type: String, error_: String, textClass: String)] = [
            ("NSError with a framework domain",
             NSError(domain: "com.apple.coreaudio.avfaudio", code: 561_015_905, userInfo: [NSLocalizedDescriptionKey: "Session activation failed"]),
             "NSError", "com.apple.coreaudio.avfaudio#561015905", "plain"),
            ("an NSError whose domain holds text", NSError(domain: "Could not open /Users/me/Secret", code: 3),
             "NSError", "other#3", "generic"),
            ("a message that looks like code", Dump(), "Dump", "other#1", "generic"),
            ("an enum case", Coded.sessionActivationFailed, "Coded", "other#0:sessionActivationFailed", "generic"),
        ]
        for c in cases {
            let fields = MarginReturnResume.failureFields(c.error, appIsInBackground: true, willRetry: true)
            XCTAssertEqual(fields["errorType"], c.type, c.name)
            XCTAssertEqual(fields["error"], c.error_, c.name)
            XCTAssertEqual(fields["textClass"], c.textClass, c.name)
            XCTAssertFalse(fields.values.contains { $0.contains("Secret") }, c.name)
        }
    }

    func testTheRetryWaitIsOneShortDelay() {
        XCTAssertEqual(MarginReturnResume.retryDelaysMs, [1_500])
    }
}
