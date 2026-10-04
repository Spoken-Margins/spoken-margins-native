import XCTest
@testable import SessionKit

/// #64: the rules the preparation pass checks before every chunk.
final class PreparationChunkGateTests: XCTestCase {
    private let allPolicies: [PreparationJobPolicy] = [.explicit, .demandWindow, .whileCharging]

    func testSeriousOrCriticalHeatPausesEveryJobIncludingExplicit() {
        for thermal in [SpeechThermalLevel.serious, .critical] {
            for policy in allPolicies {
                XCTAssertEqual(
                    PreparationChunkGate.decide(policy: policy, thermal: thermal, isLowPowerModeEnabled: false, itemAlreadyListened: false),
                    .pauseForHeat,
                    "\(policy) at \(thermal)"
                )
            }
            XCTAssertFalse(PreparationChunkGate.allowsAutomaticWork(thermal: thermal, isLowPowerModeEnabled: false))
        }
    }

    func testNominalAndFairHeatRender() {
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            for policy in allPolicies {
                XCTAssertEqual(
                    PreparationChunkGate.decide(policy: policy, thermal: thermal, isLowPowerModeEnabled: false, itemAlreadyListened: false),
                    .render,
                    "\(policy) at \(thermal)"
                )
            }
            XCTAssertTrue(PreparationChunkGate.allowsAutomaticWork(thermal: thermal, isLowPowerModeEnabled: false))
        }
    }

    func testLowPowerModeHoldsAutomaticWorkButNotAnExplicitPrepare() {
        XCTAssertEqual(
            PreparationChunkGate.decide(policy: .whileCharging, thermal: .nominal, isLowPowerModeEnabled: true, itemAlreadyListened: false),
            .waitForLowPowerMode
        )
        XCTAssertEqual(
            PreparationChunkGate.decide(policy: .demandWindow, thermal: .nominal, isLowPowerModeEnabled: true, itemAlreadyListened: false),
            .waitForLowPowerMode
        )
        XCTAssertEqual(
            PreparationChunkGate.decide(policy: .explicit, thermal: .nominal, isLowPowerModeEnabled: true, itemAlreadyListened: false),
            .render
        )
        XCTAssertFalse(PreparationChunkGate.allowsAutomaticWork(thermal: .nominal, isLowPowerModeEnabled: true))
    }

    func testHeatStillPausesAnExplicitPrepareInLowPowerMode() {
        XCTAssertEqual(
            PreparationChunkGate.decide(policy: .explicit, thermal: .serious, isLowPowerModeEnabled: true, itemAlreadyListened: false),
            .pauseForHeat
        )
    }

    func testExplicitPrepareOverridesTheListenedSkip() {
        XCTAssertEqual(
            PreparationChunkGate.decide(policy: .explicit, thermal: .nominal, isLowPowerModeEnabled: false, itemAlreadyListened: true),
            .render
        )
        for policy in [PreparationJobPolicy.demandWindow, .whileCharging] {
            XCTAssertEqual(
                PreparationChunkGate.decide(policy: policy, thermal: .nominal, isLowPowerModeEnabled: false, itemAlreadyListened: true),
                .dropListenedItem,
                "\(policy)"
            )
            // Dropping renders nothing, so heat and Low Power Mode don't keep a listened job queued.
            XCTAssertEqual(
                PreparationChunkGate.decide(policy: policy, thermal: .critical, isLowPowerModeEnabled: true, itemAlreadyListened: true),
                .dropListenedItem,
                "\(policy) while hot"
            )
        }
    }

    func testLowPowerModeHoldsOnlyJobsTheListenerDidNotAskFor() {
        XCTAssertTrue(PreparationChunkGate.holdsForLowPowerMode(.whileCharging, isLowPowerModeEnabled: true))
        XCTAssertTrue(PreparationChunkGate.holdsForLowPowerMode(.demandWindow, isLowPowerModeEnabled: true))
        XCTAssertFalse(PreparationChunkGate.holdsForLowPowerMode(.explicit, isLowPowerModeEnabled: true))
        for policy in allPolicies {
            XCTAssertFalse(PreparationChunkGate.holdsForLowPowerMode(policy, isLowPowerModeEnabled: false))
        }
    }

    /// The same cases the app tested on `Gate1AppModel.shouldSkipTextAudioPreparation` before the move.
    func testItemAlreadyListenedAtTheCutoffOrWhenFinished() {
        let atCutoff = session(id: "at-cutoff", percent: 99)
        let belowCutoff = session(id: "below-cutoff", percent: 98)
        var finished = belowCutoff
        finished.id = "finished"
        finished.status = "finished"
        finished.phase = .finished
        finished.completionPercent = 12
        var completedAtOnly = belowCutoff
        completedAtOnly.id = "completed-at"
        completedAtOnly.completedAt = Date(timeIntervalSince1970: 1)

        XCTAssertFalse(PreparationChunkGate.itemAlreadyListened([]))
        XCTAssertFalse(PreparationChunkGate.itemAlreadyListened([belowCutoff]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([atCutoff]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([finished]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([completedAtOnly]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([belowCutoff, finished]))
    }

    func testHeatPauseSavesPausedForThermalOnlyOnAnActiveManifest() {
        XCTAssertEqual(PreparationChunkGate.manifestState(after: .pauseForHeat, current: .preparing), .pausedForThermal)
        XCTAssertNil(PreparationChunkGate.manifestState(after: .pauseForHeat, current: .pausedForThermal))
        for state in [PreparedAudioState.readyOffline, .stopped, .failed, .needsRepreparation, .notPrepared] {
            XCTAssertNil(PreparationChunkGate.manifestState(after: .pauseForHeat, current: state), "\(state) must not be overwritten")
        }
    }

    func testRenderingAgainResumesOnlyAHeatPausedManifest() {
        XCTAssertEqual(PreparationChunkGate.manifestState(after: .render, current: .pausedForThermal), .preparing)
        for state in [PreparedAudioState.preparing, .readyOffline, .stopped, .failed, .needsRepreparation, .notPrepared] {
            XCTAssertNil(PreparationChunkGate.manifestState(after: .render, current: state), "\(state)")
        }
        for decision in [PreparationChunkDecision.waitForLowPowerMode, .dropListenedItem] {
            XCTAssertNil(PreparationChunkGate.manifestState(after: decision, current: .preparing))
            XCTAssertNil(PreparationChunkGate.manifestState(after: decision, current: .pausedForThermal))
        }
    }

    /// The pass renders one chunk per call. Heat in the middle of an article pauses it with the
    /// committed chunks kept, and cooling resumes at the first missing chunk: no chunk renders twice.
    func testHeatMidArticlePausesAndResumesWithoutRenderingAChunkTwice() {
        let plannedChunks = 6
        var committed: Set<Int> = []
        var renders: [Int] = []
        var state = PreparedAudioState.preparing
        let heatPerPass: [SpeechThermalLevel] = [.nominal, .fair, .serious, .critical, .serious, .fair, .nominal, .nominal, .nominal, .nominal]
        var pausedPasses = 0
        for thermal in heatPerPass {
            guard let next = (0..<plannedChunks).first(where: { !committed.contains($0) }) else { break }
            let decision = PreparationChunkGate.decide(policy: .whileCharging, thermal: thermal, isLowPowerModeEnabled: false, itemAlreadyListened: false)
            if let newState = PreparationChunkGate.manifestState(after: decision, current: state) { state = newState }
            guard decision == .render else {
                XCTAssertEqual(state, .pausedForThermal)
                pausedPasses += 1
                continue
            }
            XCTAssertEqual(state, .preparing)
            renders.append(next)
            committed.insert(next)
        }
        XCTAssertEqual(pausedPasses, 3)
        XCTAssertEqual(renders, Array(0..<plannedChunks))
    }

    private func session(id: String, percent: Int) -> Session {
        Session(
            id: id,
            itemId: "item",
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: "item",
            position: Position(charOffset: percent * 10),
            completionPercent: percent,
            playbackRate: 1
        )
    }
}
