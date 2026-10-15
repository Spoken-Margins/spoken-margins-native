import Foundation
import XCTest
@testable import SessionKit

/// The pacing and resource rules every on-device voice goes through (#1679). Moved here from
/// SupertonicNarrationTests so they run on Linux too.
final class OnDeviceVoiceGovernorTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var wall: TimeInterval = 0
        private var cpu: TimeInterval = 0
        private var sleeps: [TimeInterval] = []

        var now: TimeInterval { lock.withLock { wall } }
        var cpuTime: TimeInterval { lock.withLock { cpu } }
        var requestedSleeps: [TimeInterval] { lock.withLock { sleeps } }
        var sleptTotal: TimeInterval { lock.withLock { sleeps.reduce(0, +) } }

        func run(wall seconds: TimeInterval, cpu cpuSeconds: TimeInterval) {
            lock.withLock { wall += seconds; cpu += cpuSeconds }
        }

        func sleep(_ seconds: TimeInterval) {
            lock.withLock { sleeps.append(seconds); wall += seconds }
        }
    }

    private func governor(_ clock: FakeClock, conditions: SpeechEngineConditions = SpeechEngineConditions()) -> OnDeviceVoiceGovernor {
        OnDeviceVoiceGovernor(
            conditions: { conditions }, now: { clock.now }, cpuTime: { clock.cpuTime }, sleep: { clock.sleep($0) }
        )
    }

    func testBackgroundInferencePacingLeavesSafetyMarginBelowIOSCPUQuota() {
        XCTAssertEqual(OnDeviceInferencePacingPolicy.delay(afterInferenceDuration: 10, backgrounded: false), 0)
        let delay = OnDeviceInferencePacingPolicy.delay(afterInferenceDuration: 10, backgrounded: true)
        XCTAssertEqual(delay, 5.384615, accuracy: 0.000_001)
        XCTAssertEqual(10 / (10 + delay), 0.65, accuracy: 0.000_001)
    }

    // #1101: a background wake can arrive later than requested. That elapsed time has already
    // paced inference; repeatedly subtracting only 100 ms charges the same scheduler delay again.
    func testBackgroundPacingCountsActualElapsedTimeWhenSleepOvershoots() {
        let delay = OnDeviceInferencePacingPolicy.delay(afterInferenceDuration: 10, backgrounded: true)
        var elapsed: TimeInterval = 0
        var sleeps = 0
        OnDeviceInferencePacingPolicy.wait(for: delay, now: { elapsed }, sleep: { requested in
            sleeps += 1
            elapsed += requested + 2 // a delayed background wake, without a real wall-clock sleep
        }, shouldContinue: { true })
        XCTAssertEqual(sleeps, 3, "once the budget has elapsed, no more sleeps may be requested")
        XCTAssertLessThan(elapsed, delay + 2.1)
    }

    func testCancelledBackgroundPacingReleasesTheObsoleteRenderOnTheNextWake() {
        var elapsed: TimeInterval = 0
        var cancelled = false
        var sleeps = 0
        XCTAssertThrowsError(try OnDeviceInferencePacingPolicy.wait(for: 5, now: { elapsed }, sleep: { requested in
            sleeps += 1
            elapsed += requested
            cancelled = true
        }, shouldContinue: {
            if cancelled { throw CancellationError() }
            return true
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sleeps, 1)
    }

    func testForegroundingStopsBackgroundPacingOnTheNextWake() {
        var elapsed: TimeInterval = 0
        var backgrounded = true
        var sleeps = 0
        OnDeviceInferencePacingPolicy.wait(for: 5, now: { elapsed }, sleep: { requested in
            sleeps += 1
            elapsed += requested
            backgrounded = false
        }, shouldContinue: { backgrounded })
        XCTAssertEqual(sleeps, 1)
    }

    // #1679: an inference on two threads spends more CPU than wall time, and iOS counts CPU. Holding only the wall
    // time to 65% would still let such a voice use 130% of a core in the background.
    func testMultiThreadedInferenceRestsUntilTheProcessCPUIsUnderTheDutyCycle() {
        let cost = OnDeviceVoiceGovernor.InferenceCost(wall: 2, cpu: 3.6)
        let delay = OnDeviceInferencePacingPolicy.delay(after: cost, backgrounded: true)
        XCTAssertEqual(3.6 / (2 + delay), 0.65, accuracy: 0.000_001)
        XCTAssertEqual(OnDeviceInferencePacingPolicy.delay(after: cost, backgrounded: false), 0)
        // One thread, partly idle: paced on the wall time exactly as before (#1101).
        XCTAssertEqual(
            OnDeviceInferencePacingPolicy.delay(after: .init(wall: 10, cpu: 8.5), backgrounded: true),
            OnDeviceInferencePacingPolicy.delay(afterInferenceDuration: 10, backgrounded: true)
        )
    }

    // #1679: the app's background state lives in one governor that every voice shares, so a voice that takes over
    // in the background (Kitten after heat) is paced from its first render, and a renderer built while the app is
    // away starts paced.
    func testEveryVoiceOnTheGovernorIsPacedOnceTheAppIsInTheBackground() {
        let clock = FakeClock()
        let shared = governor(clock)
        let inference = OnDeviceVoiceGovernor.InferenceCost(wall: 1, cpu: 1.8)

        shared.rest(after: inference, pacing: .whenAppBackgrounded)
        XCTAssertEqual(clock.sleptTotal, 0, "live narration in front is never held back")

        shared.setAppBackgrounded(true)
        shared.rest(after: inference, pacing: .whenAppBackgrounded)
        XCTAssertEqual(clock.sleptTotal, 1.8 / 0.65 - 1, accuracy: 0.001, "a backgrounded render waits before the next")

        shared.setAppBackgrounded(false)
        let before = clock.sleptTotal
        shared.rest(after: inference, pacing: .always)
        XCTAssertGreaterThan(clock.sleptTotal - before, 0, "background preparation is paced in front too (#377)")
    }

    func testMeasureInferenceReportsWallAndProcessCPU() {
        let clock = FakeClock()
        let measured = governor(clock).measureInference { () -> Int in
            clock.run(wall: 2, cpu: 3.5)
            return 7
        }
        XCTAssertEqual(measured.value, 7)
        XCTAssertEqual(measured.cost, OnDeviceVoiceGovernor.InferenceCost(wall: 2, cpu: 3.5))
    }

    func testSupertonicBlockFollowsTheDeviceConditions() {
        let clock = FakeClock()
        XCTAssertNil(governor(clock).supertonicRenderingBlock())
        XCTAssertEqual(governor(clock, conditions: .init(thermal: .serious)).supertonicRenderingBlock(), .deviceTooWarm)
        XCTAssertEqual(
            governor(clock, conditions: .init(isRecoveringFromMemoryWarning: true)).supertonicRenderingBlock(), .memoryWarning
        )
        XCTAssertNil(governor(clock, conditions: .init(isLowPowerModeEnabled: true)).supertonicRenderingBlock(),
                     "Low Power Mode alone never changes the voice (#183)")
    }
}
