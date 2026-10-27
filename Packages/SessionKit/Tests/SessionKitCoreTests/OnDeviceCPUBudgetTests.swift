import Foundation
import XCTest
@testable import SessionKit

/// #2695: one background CPU budget for every on-device renderer in the process.
final class OnDeviceCPUBudgetTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
        var cpu: TimeInterval = 0
    }

    /// The playing client's state, which a seek or skip changes without telling the governor.
    private final class LiveState: @unchecked Sendable {
        var buffer: LiveNarrationBuffer?
        init(_ buffer: LiveNarrationBuffer?) { self.buffer = buffer }
    }

    private func governor(_ clock: Clock) -> OnDeviceVoiceGovernor {
        let governor = OnDeviceVoiceGovernor(
            conditions: { SpeechEngineConditions(thermal: .fair) },
            now: { clock.now }, cpuTime: { clock.cpu }, sleep: { clock.now += $0 }
        )
        governor.setAppBackgrounded(true)
        return governor
    }

    /// A renderer in the simulation: each inference takes `wall` seconds and uses `cpu` seconds of CPU.
    private struct Renderer {
        let pacing: OnDeviceRenderPacing
        let wall: TimeInterval
        let cpu: TimeInterval
        var notBefore: TimeInterval?
        var runsUntil: TimeInterval?
        var reserved: TimeInterval = 0
        var inferences = 0
    }

    /// Runs `renderers` side by side for `duration` seconds in 50 ms ticks, each pacing through one governor the way
    /// Kitten does (`nextInference` then the shared budget before the next start), and returns CPU used per tick.
    private func simulate(_ renderers: inout [Renderer], governor: OnDeviceVoiceGovernor, clock: Clock,
                          duration: TimeInterval) -> [TimeInterval] {
        let tick = 0.05
        var usage: [TimeInterval] = []
        for step in 0..<Int(duration / tick) {
            clock.now = TimeInterval(step) * tick
            var used: TimeInterval = 0
            for index in renderers.indices {
                var renderer = renderers[index]
                if let end = renderer.runsUntil, clock.now >= end - 1e-9 {
                    governor.settleInference(reserved: renderer.reserved, cpu: renderer.cpu)
                    renderer.notBefore = governor.nextInference(
                        after: .init(wall: renderer.wall, cpu: renderer.cpu), pacing: renderer.pacing)
                    renderer.runsUntil = nil
                }
                if renderer.runsUntil == nil, clock.now >= (renderer.notBefore ?? 0) - 1e-9,
                   governor.budgetStart(for: renderer.pacing) == nil {
                    renderer.reserved = governor.reserveInference()
                    renderer.runsUntil = clock.now + renderer.wall
                    renderer.inferences += 1
                }
                if renderer.runsUntil != nil { used += renderer.cpu / renderer.wall * tick }
                renderers[index] = renderer
            }
            usage.append(used)
        }
        return usage
    }

    private func busiestMinute(_ usage: [TimeInterval]) -> TimeInterval {
        let width = Int(OnDeviceCPUBudget.window / 0.05)
        var sum = usage.prefix(width).reduce(0, +)
        var busiest = sum
        for index in width..<usage.count {
            sum += usage[index] - usage[index - width]
            busiest = max(busiest, sum)
        }
        return busiest
    }

    /// The owner's 10-25 kill: live Kitten and a Library Supertonic render each paced to 65% on their own, and together
    /// used about 1.3 cores in the background. Through one budget they stay at or under 0.6 of a core in every minute.
    func testTwoRenderersTogetherStayAtOrUnderTheBudget() {
        let clock = Clock()
        let governor = governor(clock)
        var renderers = [
            Renderer(pacing: .whenAppBackgrounded, wall: 2, cpu: 2), // Kitten: one thread, a chunk at a time
            Renderer(pacing: .always, wall: 0.5, cpu: 1) // Supertonic: two ONNX threads, short steps
        ]
        let usage = simulate(&renderers, governor: governor, clock: clock, duration: 600)
        let limit = OnDeviceCPUBudget.backgroundCoreShare * OnDeviceCPUBudget.window
        XCTAssertLessThanOrEqual(busiestMinute(usage), limit + 0.001)
        XCTAssertGreaterThan(renderers[0].inferences, 0)
        XCTAssertGreaterThan(renderers[1].inferences, 0)
        // The budget is shared, not wasted: over ten minutes the renderers use most of it.
        XCTAssertGreaterThan(usage.reduce(0, +), 0.8 * OnDeviceCPUBudget.backgroundCoreShare * 600)
    }

    func testOneRendererAloneStaysUnderTheBudgetToo() {
        let clock = Clock()
        let governor = governor(clock)
        var renderers = [Renderer(pacing: .always, wall: 0.5, cpu: 1)]
        let usage = simulate(&renderers, governor: governor, clock: clock, duration: 300)
        XCTAssertLessThanOrEqual(busiestMinute(usage), OnDeviceCPUBudget.backgroundLimit + 0.001)
    }

    /// The budget may slow render-ahead, but live narration that is running low never waits on it.
    func testLiveNarrationRunningLowSkipsTheBudgetAndOtherRendersStillWait() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        clock.now = 30
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        XCTAssertNotNil(governor.budgetStart(for: .whenAppBackgrounded), "a full budget holds live render-ahead")
        XCTAssertNotNil(governor.budgetStart(for: .always))

        let live = LiveState(LiveNarrationBuffer(listeningAhead: 30, playheadWaitsForAudio: false))
        governor.readLiveNarrationBuffer { live.buffer }
        XCTAssertNil(governor.budgetStart(for: .whenAppBackgrounded), "the playing buffer wins")
        XCTAssertNotNil(governor.budgetStart(for: .always), "Library work still waits")

        live.buffer = LiveNarrationBuffer(listeningAhead: 200, playheadWaitsForAudio: false)
        XCTAssertNotNil(governor.budgetStart(for: .whenAppBackgrounded), "plenty ahead: render-ahead waits")
        clock.now = 30 + OnDeviceCPUBudget.window + 0.01
        XCTAssertNil(governor.budgetStart(for: .always), "the spend has left the window")
    }

    func testTheBudgetHoldsNothingInTheForeground() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        governor.setAppBackgrounded(false)
        XCTAssertNil(governor.budgetStart(for: .whenAppBackgrounded))
        XCTAssertNil(governor.budgetStart(for: .always))
    }

    /// Supertonic's ONNX threads use more CPU than wall time; the budget charges the CPU.
    func testAMeasuredInferenceIsChargedItsCPUTimeNotItsWallTime() {
        let clock = Clock()
        let governor = governor(clock)
        let (_, cost) = governor.measureInference { clock.now += 1; clock.cpu += 2 }
        XCTAssertEqual(cost.cpu, 2)
        XCTAssertEqual(governor.budgetSpent(), 2, accuracy: 1e-9)
    }

    /// Review of #2739: the client used to push "live needs audio" only when a chunk finished, so after a background
    /// seek or skip, or a start on an unrendered chunk, the governor still held the last chunk's answer (plenty ahead)
    /// and the new chain's first render waited on a full budget: seconds of silence, then a hand-over at the seam. The
    /// governor now reads the client's state at each check, so the seek is seen with no setter to forget.
    func testAfterABackgroundSeekTheNewRenderStartsWithoutABudgetWait() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        // A chunk just finished with five minutes waiting ahead: render-ahead rests on the full budget.
        let live = LiveState(LiveNarrationBuffer(listeningAhead: 300, playheadWaitsForAudio: false))
        governor.readLiveNarrationBuffer { live.buffer }
        XCTAssertNotNil(governor.budgetStart(for: .whenAppBackgrounded), "precondition: the budget holds render-ahead")

        // The listener seeks to an unrendered spot: nothing waits past the play head, and it waits on audio.
        live.buffer = LiveNarrationBuffer(listeningAhead: 0, playheadWaitsForAudio: true)
        let before = clock.now
        governor.waitForNextInference(notBefore: nil, pacing: .whenAppBackgrounded) { true }
        XCTAssertEqual(clock.now, before, "the render the play head waits on starts at once")
        XCTAssertNotNil(governor.budgetStart(for: .always), "Library work still waits on the full budget")
    }

    /// A render the play head is waiting on never waits on the budget, however much is rendered elsewhere ahead
    /// (Supertonic's last step rests through `rest(after:)`, which waited on the budget and held a finished chunk).
    func testARenderThePlayheadWaitsOnNeverWaitsOnTheBudget() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        let live = LiveState(LiveNarrationBuffer(listeningAhead: 600, playheadWaitsForAudio: true))
        governor.readLiveNarrationBuffer { live.buffer }
        XCTAssertNil(governor.budgetStart(for: .whenAppBackgrounded))
        let cost = OnDeviceVoiceGovernor.InferenceCost(wall: 1, cpu: 1)
        governor.rest(after: cost, pacing: .whenAppBackgrounded) { true }
        let dutyCycleRest = OnDeviceInferencePacingPolicy.delay(after: cost, backgrounded: true)
        XCTAssertEqual(clock.now, dutyCycleRest, accuracy: 0.11, "only the voice's own duty cycle, not the budget")
    }

    /// With no client playing, nothing is live: every render waits on the budget as before.
    func testWithNoPlayingClientLiveRenderAheadWaitsOnTheBudget() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        governor.readLiveNarrationBuffer { nil }
        XCTAssertFalse(governor.liveNarrationNeedsAudio)
        XCTAssertNotNil(governor.budgetStart(for: .whenAppBackgrounded))
    }

    /// A render waiting on a full budget wakes once the spend leaves the window, and not before.
    func testWaitForNextInferenceWaitsOutAFullBudget() {
        let clock = Clock()
        let governor = governor(clock)
        let reserved = governor.reserveInference()
        governor.settleInference(reserved: reserved, cpu: OnDeviceCPUBudget.backgroundLimit)
        governor.waitForNextInference(notBefore: nil, pacing: .always) { true }
        XCTAssertGreaterThan(clock.now, OnDeviceCPUBudget.window - 0.001)
        XCTAssertLessThan(clock.now, OnDeviceCPUBudget.window + 0.2)
    }
}
