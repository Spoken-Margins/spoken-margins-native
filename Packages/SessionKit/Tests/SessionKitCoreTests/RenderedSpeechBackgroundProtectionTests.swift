import XCTest
@testable import SessionKit

@MainActor
final class RenderedSpeechBackgroundProtectionTests: XCTestCase {
    func testBackgroundRenderAndNextChunkQueueingRemainProtectedWithEitherPowerMode() async {
        // Power mode is deliberately not an input to the protection: both modes need it.
        // This models lifecycle ordering, not iOS's real scheduling or audible playback.
        for lowPowerMode in [false, true] {
            XCTAssertNil(SpeechEnginePolicy.onDeviceRenderingBlock(
                SpeechEngineConditions(isLowPowerModeEnabled: lowPowerMode)))
            let time = BackgroundTime()
            var rendered = false
            var queued = false
            await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: { _ in
                XCTFail("Unexpected stop with lowPowerMode=\(lowPowerMode)")
            }) {
                XCTAssertEqual(time.active, 1, "render must hold time before audio can run out")
                await Task.yield()
                rendered = true
                XCTAssertEqual(time.active, 1, "still protected while publishing rendered audio")
                queued = true
                XCTAssertEqual(time.active, 1, "next chunk is queued before releasing protection")
            }
            XCTAssertTrue(rendered && queued)
            XCTAssertEqual(time.active, 0)
            XCTAssertEqual(time.ends, 1)
        }
    }

    func testExpirationReportsReasonBeforeReleasingTime() async {
        let time = BackgroundTime()
        var stops: [RenderedSpeechBackgroundProtection.Stop] = []
        await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: {
            XCTAssertEqual(time.active, 1, "hand off before giving iOS the remaining time")
            stops.append($0)
        }) {
            time.expire?()
            time.expire?()
        }
        XCTAssertEqual(stops, [.expired])
        XCTAssertEqual(stops.first?.failureCode, "supertonic_background_render_expired")
        XCTAssertEqual(time.ends, 1)
    }

    func testRefusedTimeDoesNotStartUnprotectedInference() async {
        var stops: [RenderedSpeechBackgroundProtection.Stop] = []
        var rendered = false
        await RenderedSpeechBackgroundProtection.run(begin: { _, _ in nil }, onStop: { stops.append($0) }) {
            rendered = true
        }
        XCTAssertFalse(rendered)
        XCTAssertEqual(stops, [.unavailable])
        XCTAssertEqual(stops.first?.failureCode, "supertonic_background_render_unavailable")
    }

    func testLateExpiryCannotStopCompletedOrFollowingRender() async {
        let time = BackgroundTime()
        var oldExpiry: (@MainActor () -> Void)?
        await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: { _ in XCTFail("Completed") }) {
            oldExpiry = time.expire
        }
        await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: { _ in XCTFail("Stale") }) {
            oldExpiry?()
            XCTAssertEqual(time.active, 1)
        }
        time.expire?()
        XCTAssertEqual(time.ends, 2)
    }

    func testCancellationReleasesTimeEvenWhenRendererHasNotReturned() async {
        let time = BackgroundTime()
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: { _ in XCTFail("Cancelled") }) {
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        task.cancel()
        // Cancellation must not wait for a non-cooperative inference call to finish.
        for _ in 0..<100 where time.ends == 0 { await Task.yield() }
        XCTAssertEqual(time.ends, 1)
        time.expire?()
        resume?.resume()
        await task.value
        XCTAssertEqual(time.ends, 1)
    }

    func testAlreadyCancelledRenderNeverAcquiresTimeOrRuns() async {
        let time = BackgroundTime()
        let task = Task { @MainActor in
            await RenderedSpeechBackgroundProtection.run(begin: time.begin, onStop: { _ in XCTFail("Cancelled") }) {
                XCTFail("Cancelled render ran")
            }
        }
        task.cancel()
        await task.value
        XCTAssertEqual(time.ends, 0)
        XCTAssertEqual(time.active, 0)
    }

    func testSynchronousExpiryDoesNotLeakTimeOrStartRendering() async {
        var ends = 0
        var stops: [RenderedSpeechBackgroundProtection.Stop] = []
        await RenderedSpeechBackgroundProtection.run(begin: { _, expired in
            expired()
            return { ends += 1 }
        }, onStop: { stops.append($0) }) {
            XCTFail("Expired render ran")
        }
        XCTAssertEqual(stops, [.expired])
        XCTAssertEqual(ends, 1)
    }

    func testBackgroundStopHasSpecificFallbackAndPreparationExplanations() async {
        for stop in [RenderedSpeechBackgroundProtection.Stop.expired, .unavailable] {
            let reason = SpeechFallbackReason(supertonicCode: stop.failureCode, resourceBlock: nil)
            XCTAssertEqual(reason, .backgroundRenderingUnavailable)
            XCTAssertTrue(reason.listenerExplanation.contains("Using the iOS voice"))
            XCTAssertTrue(reason.listenerExplanation.contains("background"))
            XCTAssertFalse(reason.returnsAutomatically)
            let stopped = SpeechGenerationStopReason.listenerExplanation(stopReason: stop.failureCode, fallbackReason: nil)
            XCTAssertTrue(stopped.contains("background"))
            XCTAssertFalse(stopped.contains("Using the iOS voice"), "buffered selected audio may still be playing")
        }
    }

    @MainActor
    private final class BackgroundTime {
        var active = 0
        var ends = 0
        var expire: (@MainActor () -> Void)?

        func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
            active += 1
            expire = expired
            return { self.active -= 1; self.ends += 1 }
        }
    }
}
