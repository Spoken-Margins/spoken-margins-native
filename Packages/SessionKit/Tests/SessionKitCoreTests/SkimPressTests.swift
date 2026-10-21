import SessionKit
import XCTest

/// #2185: Skim on a mapped podcast read no summaries. A scene with summary text but no saved audio had no Skim, so the
/// slot silently became Next chapter. Such a scene is skimmable now: the press prepares the summary first.
final class SkimPressTests: XCTestCase {
    func testASceneWithASummaryButNoAudioCanStillBeSkimmed() {
        let readiness = SkimReadiness.of(hasMap: true, hasPlan: true, hasReadyAudio: false, suppliesItsOwnVoice: false)
        XCTAssertEqual(readiness, .needsSummaryAudio)
        XCTAssertTrue(readiness.isPressable)
    }

    func testEachReadinessAndItsReason() {
        func of(map: Bool = true, plan: Bool = true, audio: Bool = false, supplied: Bool = false) -> SkimReadiness {
            SkimReadiness.of(hasMap: map, hasPlan: plan, hasReadyAudio: audio, suppliesItsOwnVoice: supplied)
        }
        XCTAssertEqual(of(audio: true), .ready)
        XCTAssertEqual(of(audio: true, supplied: true), .ready, "a supplied voice that is on the phone plays")
        XCTAssertEqual(of(supplied: true), .unavailable(.suppliedSummaryMissing),
                       "a package's recorded summary is never replaced with synthesized speech")
        XCTAssertEqual(of(plan: false, audio: true), .unavailable(.noSceneSummary))
        XCTAssertEqual(of(map: false, plan: false), .unavailable(.noMap))
        XCTAssertEqual(of(map: false, plan: true, audio: true), .unavailable(.noMap), "no map, no plan to trust")
        XCTAssertTrue(of(audio: true).isPressable)
        XCTAssertFalse(of(plan: false).isPressable)
    }

    func testEveryReasonTellsTheListenerSomething() {
        let reasons: [SkimUnavailableReason] = [
            .noSource, .noMap, .noSceneSummary, .suppliedSummaryMissing, .preparationFailed, .movedOn
        ]
        XCTAssertEqual(Set(reasons.map(\.rawValue)).count, reasons.count)
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty, reason.rawValue)
            XCTAssertFalse(reason.rawValue.contains(" "), "a Diagnostics value, not prose")
        }
    }

    func testTheDiagnosticFieldsNameTheOutcomeDirectionAndReason() {
        XCTAssertEqual(
            SkimPressOutcome.noPlan.diagnosticFields(direction: .forward, reason: SkimUnavailableReason.noMap.rawValue),
            ["outcome": "no_plan", "direction": "forward", "reason": "no_map"])
        XCTAssertEqual(SkimPressOutcome.playedSummary.diagnosticFields(direction: .backward),
                       ["outcome": "played_summary", "direction": "backward"])
    }
}
