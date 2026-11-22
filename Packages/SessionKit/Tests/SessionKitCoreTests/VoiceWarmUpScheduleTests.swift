import Foundation
import XCTest
@testable import SessionKit

/// #2856 audit: trying voices in Settings rebuilds the speech client each time. Only one warm-up may load at once, a
/// newer one cancels the one before it, and one that isn't allowed to render never starts. Moved here from the app's
/// `SupertonicSpeechTests` (#318): the schedule is Foundation only, so it runs on the host.
///
/// #3125: the tests wait for each event they need instead of sleeping for a guessed time, so a slow or loaded
/// machine can't make a warm-up start late, or a "load" finish early, and change the order they check.
final class VoiceWarmUpScheduleTests: XCTestCase {
    func testWarmUpsRunOneAtATimeAndANewerOneCancelsTheOlder() async throws {
        let tally = WarmUpTally()
        let older = WarmUpProbeRenderer(name: "older", tally: tally)
        let newer = WarmUpProbeRenderer(name: "newer", tally: tally)
        let refused = WarmUpProbeRenderer(name: "refused", tally: tally)
        let leaving = WarmUpProbeRenderer(name: "leaving", tally: tally)
        let after = WarmUpProbeRenderer(name: "after", tally: tally)
        // The schedule holds each renderer weakly, so keep them alive for the whole test, not just to their last use.
        defer { withExtendedLifetime((older, newer, refused, leaving, after)) {} }
        let schedule = VoiceWarmUpSchedule()

        schedule.schedule(older, allowed: { true }, delay: .milliseconds(10))
        try await tally.waitFor("older start")
        schedule.schedule(newer, allowed: { true }, delay: .milliseconds(10))
        try await tally.waitFor("newer start")
        XCTAssertEqual(tally.events, ["older start", "older cancelled", "newer start"])
        newer.finishLoading()
        try await tally.waitFor("newer end")

        // A renderer that isn't allowed to render never starts. Wait until its warm-up has been refused, so the
        // next one doesn't just cancel it before it gets that far.
        schedule.schedule(refused, allowed: { tally.record("refused asked"); return false }, delay: .milliseconds(10))
        try await tally.waitFor("refused asked")

        // Switching to a voice with nothing to warm (James, Lily, Kitten) stops a warm-up that is still running.
        schedule.schedule(leaving, allowed: { true }, delay: .milliseconds(10))
        try await tally.waitFor("leaving start")
        schedule.cancel()
        try await tally.waitFor("leaving cancelled")
        XCTAssertEqual(tally.events, ["older start", "older cancelled", "newer start", "newer end", "refused asked", "leaving start", "leaving cancelled"])

        // A warm-up scheduled after that waits for the cancelled one to finish: never two loads at once.
        schedule.schedule(after, allowed: { true }, delay: .milliseconds(10))
        try await tally.waitFor("after start")
        after.finishLoading()
        try await tally.waitFor("after end")
        XCTAssertEqual(tally.events, [
            "older start", "older cancelled", "newer start", "newer end", "refused asked",
            "leaving start", "leaving cancelled", "after start", "after end",
        ])
        XCTAssertEqual(tally.mostAtOnce, 1)
    }

    /// The schedule holds a renderer weakly: one that is gone by the time its delay ends is never asked to load.
    func testARendererThatIsGoneBeforeItsDelayEndsIsNeverWarmed() async throws {
        let tally = WarmUpTally()
        let schedule = VoiceWarmUpSchedule()
        var gone: WarmUpProbeRenderer? = WarmUpProbeRenderer(name: "gone", tally: tally)
        schedule.schedule(try XCTUnwrap(gone), allowed: { tally.record("gone asked"); return true }, delay: .milliseconds(100))
        gone = nil
        // Wait for the warm-up to reach its check, so the next one doesn't just cancel it before it gets that far.
        try await tally.waitFor("gone asked")
        let kept = WarmUpProbeRenderer(name: "kept", tally: tally)
        defer { withExtendedLifetime(kept) {} }
        schedule.schedule(kept, allowed: { true }, delay: .milliseconds(10))
        try await tally.waitFor("kept start")
        kept.finishLoading()
        try await tally.waitFor("kept end")
        XCTAssertEqual(tally.events, ["gone asked", "kept start", "kept end"])
    }
}

/// Records the order of warm-ups and how many ran at the same moment (#2856).
private final class WarmUpTally: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var running = 0
    private var most = 0

    var events: [String] { lock.withLock { log } }
    var mostAtOnce: Int { lock.withLock { most } }

    func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func began(_ name: String) {
        lock.withLock { running += 1; most = max(most, running); log.append("\(name) start") }
    }

    func finished(_ name: String, cancelled: Bool) {
        lock.withLock { running -= 1; log.append("\(name) \(cancelled ? "cancelled" : "end")") }
    }

    /// Returns once `event` is in the log. The limit only keeps a broken run from hanging; no passing run depends on it.
    func waitFor(_ event: String, limit: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + limit
        while !events.contains(event) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for \"\(event)\"; saw \(events)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A renderer whose warm-up keeps "loading" until the test calls `finishLoading()`, or its task is cancelled (#2856, #3125).
private final class WarmUpProbeRenderer: VoiceWarmUpRendering, @unchecked Sendable {
    private let name: String
    private let tally: WarmUpTally
    private let lock = NSLock()
    private var loadingFinished = false

    init(name: String, tally: WarmUpTally) {
        self.name = name
        self.tally = tally
    }

    func finishLoading() {
        lock.withLock { loadingFinished = true }
    }

    func prepareToRender() async {
        tally.began(name)
        var cancelled = false
        do {
            while !lock.withLock({ loadingFinished }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch { cancelled = true }
        tally.finished(name, cancelled: cancelled)
    }
}
