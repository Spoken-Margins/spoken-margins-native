import Foundation
import XCTest
@testable import SessionKit

/// #3936: iOS stopped the app three times for what it did in the background (#1679 and #2695 for CPU, #2184 for a
/// frozen main thread), and no host test could say whether iOS would. `SimulatedIOSBackground` keeps iOS's books on a
/// fake clock, so the tests below grade the app against iOS's thresholds, not against its own budget.
final class BackgroundKillSeamTests: XCTestCase {
    // MARK: - The meter itself: each case is one place the rule could be read wrongly

    func testSteadyCPUUnderTheLimitLivesForTenMinutes() {
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        for _ in 0..<600 { ios.advance(wall: 1, cpu: 0.79) }
        XCTAssertNil(ios.kill)
        XCTAssertEqual(ios.busiestBackgroundWindowCPU, 0.79 * 60, accuracy: 0.01)
    }

    func testSteadyCPUOverTheLimitIsStoppedJustPastFiftySeconds() throws {
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        for _ in 0..<600 { ios.advance(wall: 1, cpu: 0.85) }
        let kill = try XCTUnwrap(ios.kill)
        XCTAssertEqual(kill.at, 57, accuracy: 1, "0.85 of a core passes 48 s of CPU after 56.5 s")
        guard case .cpuResource(let used, let window) = kill.reason else { return XCTFail("\(kill.reason)") }
        XCTAssertGreaterThan(used, ios.rules.cpuLimit)
        XCTAssertEqual(window, 60, accuracy: 3)
    }

    func testSeveralThreadsCountTheirCPUTogether() {
        // Two ONNX threads for 25 s: 50 s of CPU in 25 s of wall time.
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        for _ in 0..<25 { ios.advance(wall: 1, cpu: 2) }
        XCTAssertNotNil(ios.kill)
    }

    func testABurstThatLeavesTheWindowIsForgotten() {
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        for _ in 0..<40 { ios.advance(wall: 1, cpu: 1) } // 40 s of CPU
        for _ in 0..<61 { ios.advance(wall: 1) } // a minute of rest
        for _ in 0..<40 { ios.advance(wall: 1, cpu: 1) } // another 40 s
        XCTAssertNil(ios.kill, "no minute held more than 40 s")
        XCTAssertEqual(ios.busiestBackgroundWindowCPU, 40, accuracy: 0.01)
    }

    func testOneBigStepIsSpreadOverItsWallTimeNotCountedAtTheEnd() {
        // One step of 50 s of CPU over 100 s of wall time puts only 30 s of it in any trailing minute.
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        ios.advance(wall: 100, cpu: 50)
        XCTAssertNil(ios.kill)
        XCTAssertEqual(ios.busiestBackgroundWindowCPU, 30, accuracy: 0.01)
    }

    func testCPUInTheForegroundIsNotCountedAgainstTheBackgroundLimit() {
        let ios = SimulatedIOSBackground()
        for _ in 0..<300 { ios.advance(wall: 1, cpu: 1) } // five minutes flat out, app in front
        ios.enterBackground()
        for _ in 0..<120 { ios.advance(wall: 1, cpu: 0.5) }
        XCTAssertNil(ios.kill)
        XCTAssertEqual(ios.busiestBackgroundWindowCPU, 30, accuracy: 0.01)
    }

    func testTheCPUClockAndTheWallClockAreWhatCodeUnderTestReads() {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.1)
        ios.advance(wall: 10, cpu: 4)
        ios.sleep(5)
        XCTAssertEqual(ios.uptime(), 15, accuracy: 1e-9)
        XCTAssertEqual(ios.processCPUTime(), 4 + 1.5, accuracy: 1e-9, "the player's own 10% is on the process clock too")
    }

    func testAMainThreadStallEndsTheAppInTheBackgroundOrDuringASceneChangeOnlyPastTheLimit() throws {
        let background = SimulatedIOSBackground()
        background.enterBackground()
        background.blockMainThread(for: 9)
        XCTAssertNil(background.kill, "9 s is under the limit")
        background.blockMainThread(for: 10)
        let kill = try XCTUnwrap(background.kill)
        XCTAssertEqual(kill.reason, .watchdog(stall: 10))
        XCTAssertTrue(kill.whileBackgrounded)

        // #2184: back in front, the main thread still blocked when iOS looks.
        let returning = SimulatedIOSBackground()
        returning.enterBackground()
        returning.advance(wall: 90)
        returning.enterForeground()
        returning.blockMainThread(for: 12)
        XCTAssertEqual(returning.kill?.reason, .watchdog(stall: 12))
        XCTAssertEqual(returning.kill?.whileBackgrounded, false)

        let settled = SimulatedIOSBackground()
        settled.enterBackground()
        settled.enterForeground()
        settled.sceneDidSettle()
        settled.blockMainThread(for: 12)
        XCTAssertNil(settled.kill, "an ordinary foreground stall is a hang, which the hang probe records; iOS does not end the app for it")
    }

    func testTheFirstKillStaysAndTimeGoesOn() throws {
        let ios = SimulatedIOSBackground()
        ios.enterBackground()
        for _ in 0..<120 { ios.advance(wall: 1, cpu: 1) }
        let first = try XCTUnwrap(ios.kill)
        for _ in 0..<60 { ios.advance(wall: 1, cpu: 1) }
        XCTAssertEqual(ios.kill, first)
        XCTAssertEqual(ios.uptime(), 180)
    }

    // MARK: - What the next launch hears about it

    func testTheNextLaunchNamesTheKindOfKillIosMade() throws {
        let cpu = SimulatedIOSBackground()
        cpu.enterBackground()
        for _ in 0..<70 { cpu.advance(wall: 1, cpu: 1.5) }
        var summary = PreviousRunExit.summarize(
            diagnosticPayloads: [], metricPayloads: [try XCTUnwrap(cpu.exitMetricsReport())])
        XCTAssertEqual(summary.fields["reason"], "background_cpu_limit")
        XCTAssertEqual(summary.fields["bgCpuLimit"], "1")

        let frozen = SimulatedIOSBackground()
        frozen.enterBackground()
        frozen.blockMainThread(for: 11)
        summary = PreviousRunExit.summarize(
            diagnosticPayloads: [], metricPayloads: [try XCTUnwrap(frozen.exitMetricsReport())])
        XCTAssertEqual(summary.fields["reason"], "background_watchdog")

        let fine = SimulatedIOSBackground()
        XCTAssertNil(fine.exitMetricsReport(), "an app iOS left alone has no exit to report")
    }

    // MARK: - #2695: two on-device voices in the background, graded by iOS's limit

    /// A renderer in the replay: each inference takes `wall` seconds and `cpu` CPU seconds, spread evenly over it.
    private struct Renderer {
        let name: String
        let pacing: OnDeviceRenderPacing
        let wall: TimeInterval
        let cpu: TimeInterval
        var notBefore: TimeInterval = 0
        var runsUntil: TimeInterval?
        var reserved: TimeInterval = 0
        var inferences = 0
    }

    private enum Pacing {
        /// Before #2695: each renderer rests to its own 65% duty cycle, charging only its own inference. Nobody sees what
        /// the others spend.
        case perRendererDutyCycle
        /// Since #2695: the governor's one budget, which every renderer asks before an inference starts.
        case sharedBudget
    }

    /// Runs the renderers side by side for `duration` seconds on `ios`'s clock, in 50 ms steps, and returns how many
    /// inferences each finished. The player's own 10% CPU is on the clock, as in the app.
    private func replay(_ renderers: inout [Renderer], pacing: Pacing, ios: SimulatedIOSBackground,
                        governor: OnDeviceVoiceGovernor, duration: TimeInterval) {
        let tick = 0.05
        while ios.uptime() < duration - 1e-9 {
            let now = ios.uptime()
            var used: TimeInterval = 0
            for index in renderers.indices {
                var renderer = renderers[index]
                if let end = renderer.runsUntil, now >= end - 1e-9 {
                    switch pacing {
                    case .sharedBudget:
                        governor.settleInference(reserved: renderer.reserved, cpu: renderer.cpu)
                        renderer.notBefore = governor.nextInference(
                            after: .init(wall: renderer.wall, cpu: renderer.cpu), pacing: renderer.pacing) ?? now
                    case .perRendererDutyCycle:
                        let rest = OnDeviceInferencePacingPolicy.delay(
                            after: .init(wall: renderer.wall, cpu: renderer.cpu), backgrounded: true)
                        renderer.notBefore = now + rest
                    }
                    renderer.runsUntil = nil
                }
                if renderer.runsUntil == nil, now >= renderer.notBefore - 1e-9 {
                    if pacing == .sharedBudget {
                        if governor.budgetStart(for: renderer.pacing) != nil { renderers[index] = renderer; continue }
                        renderer.reserved = governor.reserveInference()
                    }
                    renderer.runsUntil = now + renderer.wall
                    renderer.inferences += 1
                }
                if renderer.runsUntil != nil { used += renderer.cpu / renderer.wall * tick }
                renderers[index] = renderer
            }
            ios.advance(wall: tick, cpu: used)
        }
    }

    private func ownersTwoVoices() -> [Renderer] {
        [
            Renderer(name: "Kitten stand-in (live)", pacing: .whenAppBackgrounded, wall: 2, cpu: 2),
            Renderer(name: "Supertonic Library render", pacing: .always, wall: 0.5, cpu: 1),
        ]
    }

    /// The owner's 10-25 kill (#2695), as it ran: two voices each pacing to 65% on their own. iOS ends the app inside
    /// two minutes. This is the control: it is what the meter must be able to see, or the test below proves nothing.
    func testTwoVoicesPacedOnlyEachToTheirOwnDutyCycleAreStoppedByIOS() throws {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.1)
        let governor = OnDeviceVoiceGovernor(readings: ios, conditions: { SpeechEngineConditions() })
        ios.enterBackground()
        governor.setAppBackgrounded(true)
        var renderers = ownersTwoVoices()
        replay(&renderers, pacing: .perRendererDutyCycle, ios: ios, governor: governor, duration: 600)
        let kill = try XCTUnwrap(ios.kill, "iOS would have ended the app")
        guard case .cpuResource = kill.reason else { return XCTFail("\(kill.reason)") }
        XCTAssertLessThan(kill.at, 120)
    }

    /// The same two voices through the governor as shipped: fifteen minutes in the background, never near iOS's line.
    func testTwoVoicesThroughTheSharedBudgetLiveFifteenMinutesInTheBackground() {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.1)
        let governor = OnDeviceVoiceGovernor(readings: ios, conditions: { SpeechEngineConditions() })
        ios.enterBackground()
        governor.setAppBackgrounded(true)
        var renderers = ownersTwoVoices()
        replay(&renderers, pacing: .sharedBudget, ios: ios, governor: governor, duration: 900)
        XCTAssertNil(ios.kill, "iOS would have left the app alone: \(String(describing: ios.kill))")
        XCTAssertLessThan(ios.busiestBackgroundWindowCPU, ios.rules.cpuLimit - 5,
                          "the player's decoding and the saves need room under the line, not just the inference")
        for renderer in renderers {
            XCTAssertGreaterThan(renderer.inferences, 20, "\(renderer.name) still makes progress: the budget is shared, not wasted")
        }
    }

    /// While the app is in front the governor does not pace live narration (Kitten runs flat out) and holds nothing to the
    /// shared budget; Library work (`.always`) is still paced. None of that CPU is held against the background limit.
    func testTheSameVoicesFlatOutInFrontAreNotAgainstTheBackgroundLimit() {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.1)
        let governor = OnDeviceVoiceGovernor(readings: ios, conditions: { SpeechEngineConditions() })
        governor.setAppBackgrounded(false)
        var renderers = ownersTwoVoices()
        replay(&renderers, pacing: .sharedBudget, ios: ios, governor: governor, duration: 300)
        XCTAssertNil(ios.kill)
        XCTAssertEqual(ios.busiestBackgroundWindowCPU, 0, "nothing was metered: the app never went to the background")
        XCTAssertGreaterThan(ios.processCPUTime(), 300, "the voices used more than a core between them")
        XCTAssertGreaterThan(renderers[0].inferences, 100, "Kitten ran flat out: no rest between inferences")
        XCTAssertGreaterThan(renderers[1].inferences, 150, "Library work is paced to its duty cycle even in front, and still ran")
        XCTAssertLessThan(renderers[1].inferences, 250, "Supertonic's Library render rested between inferences")
        XCTAssertNil(governor.budgetStart(for: .always), "in front the budget holds nothing")
    }

    // MARK: - #2184: the main thread frozen as the app comes back (the rule, not the app's code)

    /// The Build 35 shape: backgrounded for a minute and a half, then, as the app returns, a synchronous reload of
    /// the Skim resources (the listening map and every owned offline asset) runs on the main thread. 10 s is what
    /// the export's late checkpoint and kill imply; the figure iOS uses is not published.
    func testAReloadOnTheMainThreadAsTheAppReturnsIsAWatchdogKillTheNextLaunchNames() throws {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.05)
        ios.enterBackground()
        ios.advance(wall: 90)
        ios.enterForeground()
        ios.blockMainThread(for: 10.5, cpu: 10)
        let kill = try XCTUnwrap(ios.kill)
        XCTAssertEqual(kill.reason, .watchdog(stall: 10.5))
        let summary = PreviousRunExit.summarize(
            diagnosticPayloads: [], metricPayloads: [try XCTUnwrap(ios.exitMetricsReport())])
        XCTAssertEqual(summary.fields["reason"], "foreground_watchdog")
    }

    /// The same work in slices the main thread answers between (the 250 ms the hang probe calls a hang is far under the
    /// limit). The numbers are the test's; it pins the rule that slicing is what keeps the app alive, and the app test for
    /// the Skim reload is the guard for the code that slices it.
    func testTheSameWorkInSlicesUnderTheHangThresholdLeavesTheAppAlone() {
        let ios = SimulatedIOSBackground(idleCPUShare: 0.05)
        ios.enterBackground()
        ios.advance(wall: 90)
        ios.enterForeground()
        for _ in 0..<42 { ios.blockMainThread(for: 0.25, cpu: 0.24); ios.advance(wall: 0.05) }
        ios.sceneDidSettle()
        XCTAssertNil(ios.kill)
    }
}
