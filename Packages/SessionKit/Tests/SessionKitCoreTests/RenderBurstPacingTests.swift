import Foundation
import XCTest
@testable import SessionKit

/// #2703: live narration renders in bursts between a high-water and a low-water mark, rests longer as the phone heats,
/// and moves to a stand-in voice for heat only when the buffer would run dry.
final class RenderBurstPacingTests: XCTestCase {
    private let healthy = 3.0 // Kitten at about 3.5x real time under the budget, against 1.75x listening is 2x; 3 is ample

    func testChargingRaisesTheHighWaterMarkOnlyOnACoolPhone() {
        let charging = SpeechEngineConditions(isOnExternalPower: true)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: charging), RenderAheadPolicy.chargingWindow)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: .init(thermal: .fair, isOnExternalPower: true)),
                       RenderAheadPolicy.chargingWindow)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: .init(thermal: .serious, isOnExternalPower: true)),
                       RenderAheadPolicy.window, "a hot phone on the charger gets no longer bursts")
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true,
                                                conditions: .init(isLowPowerModeEnabled: true, isOnExternalPower: true)),
                       RenderAheadPolicy.window)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: .init(isOnExternalPower: false)), RenderAheadPolicy.window)
        XCTAssertNil(RenderAheadPolicy.window(appBackgrounded: false, conditions: charging), "in front on a cool phone: no limit")
    }

    func testRestsLengthenAsHeatRisesButNeverBelowTheFloor() {
        let window = RenderAheadPolicy.window
        func mark(_ thermal: SpeechThermalLevel, _ headroom: Double? = 3) -> TimeInterval {
            RenderAheadPolicy.resumeMark(window: window, thermal: thermal, headroom: headroom)
        }
        XCTAssertEqual(mark(.nominal), 150)
        XCTAssertEqual(mark(.fair), 120)
        XCTAssertEqual(mark(.serious), 90)
        XCTAssertGreaterThanOrEqual(mark(.serious), RenderAheadPolicy.restFloor)
        XCTAssertEqual(mark(.serious, 1.1), 150, "a voice without headroom keeps the long lead")
        XCTAssertEqual(mark(.serious, nil), 150, "nothing measured yet: the long lead")
        XCTAssertEqual(RenderAheadPolicy.resumeMark(window: RenderAheadPolicy.criticalWindow, thermal: .critical, headroom: 3), 30,
                       "critical keeps its own minute")
        XCTAssertEqual(RenderAheadPolicy.resumeMark(window: RenderAheadPolicy.chargingWindow, thermal: .nominal, headroom: 3), 300)
        XCTAssertEqual(RenderAheadPolicy.restFloor, OnDeviceCPUBudget.liveReserve, "the marks and the budget meet at one reserve")
    }

    /// #2740 review: the client kept the last chunk's headroom from any voice and app state and never cleared it, so a
    /// fast foreground Supertonic chunk lowered the background resume mark (90 s at serious instead of 150 s), and the
    /// slower paced rate could then refill too late. A reading counts only under what it was measured in.
    func testAStaleHeadroomNeverLowersTheResumeMark() {
        let item = UUID()
        let foreground = RenderHeadroomMemory.Context(isStandIn: false, isInBackground: false, generation: item)
        let background = RenderHeadroomMemory.Context(isStandIn: false, isInBackground: true, generation: item)
        var memory = RenderHeadroomMemory()
        memory.record(healthy, in: foreground)
        func mark(_ context: RenderHeadroomMemory.Context) -> TimeInterval {
            RenderAheadPolicy.resumeMark(window: RenderAheadPolicy.window, thermal: .serious, headroom: memory.headroom(in: context))
        }
        XCTAssertEqual(mark(foreground), 90, "precondition: a healthy reading lowers the mark where it was measured")
        XCTAssertEqual(mark(background), 150, "after backgrounding: the long lead, not the foreground's mark")
        XCTAssertEqual(mark(.init(isStandIn: true, isInBackground: false, generation: item)), 150, "another voice")
        XCTAssertEqual(mark(.init(isStandIn: false, isInBackground: false, generation: UUID())), 150, "another item or a seek")

        memory.record(healthy, in: background)
        XCTAssertEqual(mark(background), 90, "a background reading counts in the background")
        XCTAssertEqual(mark(foreground), 150, "and the foreground's is gone")
    }

    func testHeatDefersTheVoiceSwitchUntilTheBufferWouldRunDry() {
        XCTAssertTrue(RenderAheadPolicy.defersHeatSwitch(block: .deviceTooWarm, listeningAhead: 200))
        XCTAssertTrue(RenderAheadPolicy.defersHeatSwitch(block: .deviceTooWarm, listeningAhead: RenderAheadPolicy.restFloor + 1))
        XCTAssertFalse(RenderAheadPolicy.defersHeatSwitch(block: .deviceTooWarm, listeningAhead: RenderAheadPolicy.restFloor),
                       "at the floor the stand-in takes over")
        XCTAssertFalse(RenderAheadPolicy.defersHeatSwitch(block: .memoryWarning, listeningAhead: 300), "memory switches at once")
        XCTAssertFalse(RenderAheadPolicy.defersHeatSwitch(block: nil, listeningAhead: 300))
    }

    private struct Run {
        var bursts = 0
        var renderSeconds: TimeInterval = 0
        var minAheadAfterFilling = TimeInterval.infinity
        var switchedAt: TimeInterval?
        var aheadAtSwitch: TimeInterval?
        /// Listening ahead when the phone first turned `serious`.
        var aheadWhenHot: TimeInterval?
        var hotSince: TimeInterval?
    }

    /// 30 minutes of listening on a fake clock: 20 s chunks rendered at `headroom` times the listening speed, in the
    /// background, with the phone at `heatAt(now)`. `chosenBlocked`: Supertonic reads, and heat refuses it.
    private func listen(chosenBlocked: Bool = false, heatAt: (TimeInterval) -> SpeechThermalLevel) -> Run {
        let chunk: TimeInterval = 20, renderTime = chunk / healthy, total: TimeInterval = 30 * 60
        var run = Run(), rendered = 1, now: TimeInterval = 0, played: TimeInterval = 0, resting = false, filled = false
        var renderDone: TimeInterval? = renderTime
        while played < total {
            now += 1
            played = min(now, TimeInterval(rendered) * chunk)
            let heat = heatAt(now)
            let conditions = SpeechEngineConditions(thermal: heat)
            if let done = renderDone, now >= done { rendered += 1; renderDone = nil }
            let ahead = max(0, TimeInterval(rendered) * chunk - played - chunk)
            let window = RenderAheadPolicy.window(appBackgrounded: true, conditions: conditions)
            if heat == .serious, run.hotSince == nil { run.hotSince = now; run.aheadWhenHot = ahead }
            if let window, ahead >= window { filled = true }
            if filled, TimeInterval(rendered) * chunk < total { run.minAheadAfterFilling = min(run.minAheadAfterFilling, ahead) }
            guard renderDone == nil, TimeInterval(rendered) * chunk < total else { continue }
            let block = chosenBlocked && run.switchedAt == nil ? SpeechEnginePolicy.onDeviceRenderingBlock(conditions) : nil
            let defers = RenderAheadPolicy.defersHeatSwitch(block: block, listeningAhead: ahead)
            let resumeAt = window.map { RenderAheadPolicy.resumeMark(window: $0, thermal: heat, headroom: healthy) }
            let next = !defers && RenderAheadPolicy.rendersNext(listeningAhead: ahead, window: window, resting: resting, resumeAt: resumeAt)
            if next {
                if resting || run.bursts == 0 { run.bursts += 1 }
                if block != nil, run.switchedAt == nil { run.switchedAt = now; run.aheadAtSwitch = ahead } // the stand-in keeps the item
                renderDone = now + renderTime
                run.renderSeconds += renderTime
            }
            resting = !next
        }
        return run
    }

    func testAHotterPhoneRestsLongerWithoutTheBufferRunningDry() {
        let nominal = listen { _ in .nominal }, fair = listen { _ in .fair }, serious = listen { _ in .serious }
        XCTAssertGreaterThan(nominal.bursts, fair.bursts, "longer rests, so fewer, longer bursts: \(nominal) \(fair)")
        XCTAssertGreaterThan(fair.bursts, serious.bursts, "\(fair) \(serious)")
        for run in [nominal, fair, serious] {
            XCTAssertGreaterThanOrEqual(run.minAheadAfterFilling, RenderAheadPolicy.restFloor - 20, "never starved: \(run)")
        }
    }

    func testSeriousHeatRestsInsteadOfSwitchingWhileTheBufferHolds() throws {
        // `serious` for less time than the buffer holds past the floor, then `fair`: the rested buffer carries the hot
        // stretch and Supertonic keeps the item.
        let cooled = listen(chosenBlocked: true) { $0 < 360 ? .nominal : $0 < 400 ? .serious : .fair }
        XCTAssertGreaterThan(try XCTUnwrap(cooled.aheadWhenHot), RenderAheadPolicy.restFloor + 40, "\(cooled)")
        XCTAssertNil(cooled.switchedAt, "\(cooled)")
        // It stays hot: the switch comes only once the buffer is down to the floor, not at the first hot render.
        let stays = listen(chosenBlocked: true) { $0 < 360 ? .nominal : .serious }
        let hot = try XCTUnwrap(stays.hotSince), ahead = try XCTUnwrap(stays.aheadWhenHot)
        let switchedAt = try XCTUnwrap(stays.switchedAt, "\(stays)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(stays.aheadAtSwitch), RenderAheadPolicy.restFloor, "\(stays)")
        XCTAssertGreaterThanOrEqual(switchedAt, hot + ahead - RenderAheadPolicy.restFloor - 1, "the buffer played first: \(stays)")
        XCTAssertGreaterThanOrEqual(stays.minAheadAfterFilling, RenderAheadPolicy.restFloor - 20, "never starved: \(stays)")
    }
}
