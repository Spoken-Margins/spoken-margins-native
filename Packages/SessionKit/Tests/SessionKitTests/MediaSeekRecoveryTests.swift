import XCTest
@testable import SessionKitAudio

final class MediaSeekRecoveryTests: XCTestCase {
    func testRegularPlaybackCrossingTheTargetBandDoesNotAcceptAnUnfinishedSeek() {
        var lifecycle = MediaSeekLifecycle()
        let generation = lifecycle.begin(targetId: "episode", mediaTimeMs: 115_000,
            purpose: .navigation, originMediaTimeMs: 100_000, uptimeMs: 0)
        let requestId = lifecycle.pending?.requestId
        for uptime in stride(from: 2_000, through: 20_000, by: 2_000) {
            XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 100_000 + uptime,
                uptimeMs: uptime, playbackRate: 1), "ordinary playback at \(uptime) ms is not landing evidence")
            XCTAssertEqual(lifecycle.pending?.landingObserved, false)
        }
        guard case .retry(let retry) = lifecycle.finish(generation: generation, targetId: "episode", completed: false) else {
            return XCTFail("A later failure must retain the original navigation request's bounded retry")
        }
        XCTAssertEqual(retry.requestId, requestId)
    }

    func testBufferingBackwardSeekNeverBecomesAcceptedAtItsUnchangedOrigin() {
        var lifecycle = MediaSeekLifecycle()
        let generation = lifecycle.begin(targetId: "episode", mediaTimeMs: 100_000,
                                         purpose: .navigation, originMediaTimeMs: 105_000, uptimeMs: 0)
        let requestId = lifecycle.pending?.requestId
        for uptime in [2_000, 4_000, 10_000] {
            XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 105_000, uptimeMs: uptime, playbackRate: 1))
            XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 105_000, uptimeMs: uptime,
                                                   playbackRate: 1, observation: .nativeTimeJump))
            XCTAssertEqual(lifecycle.pending?.landingObserved, false,
                           "a native notification at an unchanged, far-away origin does not prove landing")
        }
        guard case .retry(let retry) = lifecycle.finish(generation: generation, targetId: "episode", completed: false) else {
            return XCTFail("An unlanded seek must still receive its bounded retry")
        }
        XCTAssertEqual(retry.requestId, requestId)
    }

    func testNativeJumpCanConfirmTheSamePositionThatAnOrdinarySampleCannot() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 102_000,
                            originMediaTimeMs: 100_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 102_000, uptimeMs: 2_000, playbackRate: 1))
        XCTAssertEqual(lifecycle.pending?.landingObserved, false)
        // A queued native notification may be sampled after a watchdog has seen the same time.
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 102_000, uptimeMs: 2_000,
                                               playbackRate: 1, observation: .nativeTimeJump))
        XCTAssertEqual(lifecycle.pending?.landingObserved, true)
        XCTAssertNotNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 104_000, uptimeMs: 4_000, playbackRate: 1))
    }

    func testDelayedForwardSeekRecoversAfterLandingEvenInsideOriginReach() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 102_000, originMediaTimeMs: 100_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 100_000, uptimeMs: 1_000, playbackRate: 1))
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 102_000, uptimeMs: 2_000,
                                               playbackRate: 1, observation: .nativeTimeJump))
        XCTAssertNotNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 104_000, uptimeMs: 4_000, playbackRate: 1))
        XCTAssertNil(lifecycle.pending)
    }

    func testRateReductionDoesNotErasePlaybackBeforeTheChange() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 100_000, originMediaTimeMs: 100_000, uptimeMs: 0)
        // Sample the old rate at the change boundary, even if the player has no finite time then.
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: nil, uptimeMs: 1_500, playbackRate: 2))
        XCTAssertNotNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 103_500, uptimeMs: 2_000, playbackRate: 1))
    }

    func testForwardSeekStillInFlightDoesNotRecoverFromElapsedTimeAlone() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 115_000, originMediaTimeMs: 100_000, uptimeMs: 0)
        for (uptime, position) in [(7_000, 107_000), (17_000, 117_000), (19_000, 119_000)] {
            XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: position, uptimeMs: uptime, playbackRate: 1))
        }
        XCTAssertNotNil(lifecycle.pending)
    }

    func testLandingObservationStillWaitsForPlayerMovementBeyondTolerance() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 102_000, originMediaTimeMs: 100_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 102_000, uptimeMs: 2_000,
                                               playbackRate: 1, observation: .nativeTimeJump))
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 102_000, uptimeMs: 10_000, playbackRate: 1))
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 103_000, uptimeMs: 11_000, playbackRate: 1))
        XCTAssertNotNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 104_000, uptimeMs: 12_000, playbackRate: 1))
    }

    func testSupersedingSeekDoesNotInheritLandingOrEarlierRateAllowance() {
        var lifecycle = MediaSeekLifecycle()
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 100_000, originMediaTimeMs: 100_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: nil, uptimeMs: 1_000, playbackRate: 3))
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 200_000,
                            purpose: .navigation, originMediaTimeMs: 205_000, uptimeMs: 1_000)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 205_000, uptimeMs: 5_000, playbackRate: 1))
        XCTAssertNotNil(lifecycle.pending)
    }
}
