import Foundation
import SessionKit
import XCTest

/// Found on the owner's phone (build 0.1 (35), 2026-10-18): a map job kept transcribing at serious heat for
/// 21 minutes, and diagnostics could not say what started it or why another item's job never finished.
final class EpisodeMapRunGuardTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_792_360_860) // 2026-10-18T22:01:00Z

    private func job(policy: PreparationJobPolicy = .explicit, stage: EpisodeMapPreparationStage = .transcribe) -> EpisodeMapPreparationJob {
        EpisodeMapPreparationJob(id: "episode-map-job-a", itemId: "a", policy: policy, stage: stage, nextUnitIndex: 3)
    }

    func testHeatStopsEveryRunAtSeriousOrCritical() {
        for policy in [PreparationJobPolicy.explicit, .whileCharging, .demandWindow] {
            for (level, expected) in [
                (SpeechThermalLevel.nominal, nil),
                (.fair, nil),
                (.serious, EpisodeMapRunStop.heat(.serious)),
                (.critical, .heat(.critical))
            ] {
                XCTAssertEqual(
                    EpisodeMapRunGuard.yieldReason(conditions: .init(thermal: level), policy: policy),
                    expected,
                    "\(policy) at \(level)"
                )
            }
        }
    }

    func testLowPowerModeStopsOnlyWorkTheListenerDidNotAskFor() {
        let lowPower = SpeechEngineConditions(thermal: .nominal, isLowPowerModeEnabled: true)
        XCTAssertNil(EpisodeMapRunGuard.yieldReason(conditions: lowPower, policy: .explicit))
        XCTAssertEqual(EpisodeMapRunGuard.yieldReason(conditions: lowPower, policy: .whileCharging), .lowPowerMode)
        let hotAndLowPower = SpeechEngineConditions(thermal: .serious, isLowPowerModeEnabled: true)
        XCTAssertEqual(
            EpisodeMapRunGuard.yieldReason(conditions: hotAndLowPower, policy: .whileCharging),
            .heat(.serious),
            "heat is named first, as in PreparationChunkGate"
        )
    }

    func testAPauseKeepsTheJobForALaterPassAndACancelDropsIt() {
        for stop in [EpisodeMapRunStop.heat(.serious), .lowPowerMode, .backgroundTimeExpired] {
            var paused = job()
            paused.lastFailureCode = EpisodeMapRunGuard.runningCode
            let diagnostic = EpisodeMapRunGuard.stop(stop, job: &paused, at: at)
            XCTAssertFalse(paused.isCancelled, "\(stop) keeps the job")
            XCTAssertEqual(paused.lastFailureCode, stop.code)
            XCTAssertEqual(diagnostic, "\(stop.code):stage=transcribe:at=2026-10-18T22:01:00Z")
            XCTAssertEqual(
                BackgroundPreparationPlanner.eligibleEpisodeJobs([paused], episodePolicy: .whileCharging, hasLocalAudio: { _ in true }),
                [paused],
                "the background pass can pick a paused job up again"
            )
        }
        var cancelled = job()
        _ = EpisodeMapRunGuard.stop(.cancelled, job: &cancelled, at: at)
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertEqual(cancelled.lastFailureCode, "cancelled")
    }

    func testStopCodesAreDistinct() {
        let codes = [EpisodeMapRunStop.heat(.serious), .heat(.critical), .lowPowerMode, .backgroundTimeExpired, .cancelled].map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(codes.first, "paused:heat_serious")
    }

    func testStartedDiagnosticNamesTheTriggerPolicyStageHeatAndTime() {
        XCTAssertEqual(
            EpisodeMapRunGuard.startedDiagnostic(trigger: .backgroundPass, job: job(policy: .whileCharging), thermal: .fair, at: at),
            "started:trigger=background_pass:policy=while_charging:stage=transcribe:unit=3:heat=fair:at=2026-10-18T22:01:00Z"
        )
        XCTAssertEqual(
            EpisodeMapRunGuard.waitingDiagnostic(trigger: .listenerRequest, at: at),
            "waiting_for_local_audio:trigger=listener_request:at=2026-10-18T22:01:00Z"
        )
        XCTAssertEqual(
            Set([EpisodeMapPreparationTrigger.listenerRequest, .downloadFinished, .backgroundPass].map(\.rawValue)).count, 3
        )
    }

    func testARunThatEndedWithoutRecordingIsNamedOnTheNextRequest() {
        var running = job()
        running.lastFailureCode = EpisodeMapRunGuard.runningCode
        XCTAssertEqual(
            EpisodeMapRunGuard.interruptedRunDiagnostic(previous: running),
            "previous_run_ended_unrecorded:stage=transcribe:unit=3"
        )
        XCTAssertNil(EpisodeMapRunGuard.interruptedRunDiagnostic(previous: nil))
        XCTAssertNil(EpisodeMapRunGuard.interruptedRunDiagnostic(previous: job()), "a checkpoint left the code empty")
        var paused = running
        _ = EpisodeMapRunGuard.stop(.heat(.serious), job: &paused, at: at)
        XCTAssertNil(EpisodeMapRunGuard.interruptedRunDiagnostic(previous: paused), "a recorded pause is not an interruption")
        var cancelled = running
        cancelled.isCancelled = true
        XCTAssertNil(EpisodeMapRunGuard.interruptedRunDiagnostic(previous: cancelled))
    }
}
