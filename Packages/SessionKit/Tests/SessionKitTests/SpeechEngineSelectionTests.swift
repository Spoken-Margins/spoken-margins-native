import XCTest
@testable import SessionKit

/// C2 M1 / I14 (#183): power state alone never changes the voice; any fallback has a reason and
/// comes back when the reason clears; rate is one number.
final class SpeechEngineSelectionTests: XCTestCase {
    func testLowPowerModeAndChargingAreSeparateTransitionsThatNeverBlockTheChosenVoice() {
        let transitions: [(String, SpeechEngineConditions)] = [
            ("nominal", SpeechEngineConditions()),
            ("Low Power Mode on", SpeechEngineConditions(isLowPowerModeEnabled: true, isOnExternalPower: false)),
            ("Low Power Mode off", SpeechEngineConditions(isLowPowerModeEnabled: false, isOnExternalPower: false)),
            ("plugged in", SpeechEngineConditions(isLowPowerModeEnabled: false, isOnExternalPower: true)),
            ("plugged in and warm (fair)", SpeechEngineConditions(thermal: .fair, isOnExternalPower: true)),
            ("unplugged", SpeechEngineConditions(isOnExternalPower: false)),
            ("Low Power Mode while charging", SpeechEngineConditions(isLowPowerModeEnabled: true, isOnExternalPower: true))
        ]
        for (label, conditions) in transitions {
            XCTAssertNil(SpeechEnginePolicy.onDeviceRenderingBlock(conditions), label)
        }
    }

    func testHeatAndMemoryPressureFallBackWithAReasonAndComeBackWhenTheyClear() {
        let hot = SpeechEngineConditions(thermal: .serious, isOnExternalPower: true)
        XCTAssertEqual(SpeechEnginePolicy.onDeviceRenderingBlock(hot), .deviceTooWarm)
        XCTAssertEqual(SpeechEnginePolicy.onDeviceRenderingBlock(SpeechEngineConditions(thermal: .critical)), .deviceTooWarm)
        XCTAssertFalse(SpeechEnginePolicy.restoresChosenVoice(after: .deviceTooWarm, conditions: hot))
        XCTAssertTrue(SpeechEnginePolicy.restoresChosenVoice(after: .deviceTooWarm, conditions: SpeechEngineConditions(thermal: .fair, isOnExternalPower: true)))

        let recovering = SpeechEngineConditions(isRecoveringFromMemoryWarning: true)
        XCTAssertEqual(SpeechEnginePolicy.onDeviceRenderingBlock(recovering), .memoryWarning)
        XCTAssertFalse(SpeechEnginePolicy.restoresChosenVoice(after: .memoryWarning, conditions: recovering))
        XCTAssertTrue(SpeechEnginePolicy.restoresChosenVoice(after: .memoryWarning, conditions: SpeechEngineConditions()))
    }

    func testSlowOrFailedRendersAndTheListenersOwnChoiceWaitForRetry() {
        for reason in [SpeechFallbackReason.renderTooSlow, .playbackFailed, .listenerStoppedGeneration] {
            XCTAssertFalse(SpeechEnginePolicy.restoresChosenVoice(after: reason, conditions: SpeechEngineConditions()), reason.rawValue)
        }
    }

    func testEveryFallbackNamesItsCauseForTheListenerAndTheLog() {
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_resource_pressure", resourceBlock: .memoryWarning), .memoryWarning)
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_resource_pressure", resourceBlock: .deviceTooWarm), .deviceTooWarm)
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_render_timeout", resourceBlock: nil), .renderTooSlow)
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_playback_failed", resourceBlock: nil), .playbackFailed)
        XCTAssertTrue(SpeechFallbackReason.deviceTooWarm.listenerExplanation.contains("too warm"))
        XCTAssertFalse(SpeechFallbackReason.deviceTooWarm.listenerExplanation.contains("Low Power"))
        XCTAssertTrue(SpeechFallbackReason.renderTooSlow.listenerExplanation.contains("Retry"))

        let log = SpeechEngineConditions(thermal: .serious, isLowPowerModeEnabled: true, isOnExternalPower: true).logDescription
        XCTAssertEqual(log, "thermal=serious lowPower=true power=external memoryBackoff=false")
    }

    func testRateIsOneMultiplierMappedOntoTheMeasuredSystemCurve() {
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 1), SpeechRateRule.systemDefaultRate)
        // The old mapping sent 1.75× as rate 0.875, which measured 3.1× real speed.
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 1.75), 0.62, accuracy: 0.001)
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 1.5), 0.585, accuracy: 0.001)
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 0.75), 0.31, accuracy: 0.001)
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 1.125), 0.5225, accuracy: 0.001, "interpolates")
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: 9), SpeechRateRule.systemSpeechRate(forMultiplier: 2))
        XCTAssertEqual(SpeechRateRule.systemSpeechRate(forMultiplier: .nan), SpeechRateRule.systemDefaultRate)

        var previous: Float = -1
        for step in stride(from: 0.5, through: 2.0, by: 0.05) {
            let rate = SpeechRateRule.systemSpeechRate(forMultiplier: step)
            XCTAssertGreaterThan(rate, previous, "faster multipliers are never slower (\(step))")
            previous = rate
        }

        XCTAssertEqual(SpeechRateRule.multiplier(forStoredRate: 0.875), 1.75, accuracy: 0.0001)
        XCTAssertEqual(SpeechRateRule.multiplier(forStoredRate: 0.375), 0.75, accuracy: 0.0001)
        XCTAssertEqual(SpeechRateRule.multiplier(forStoredRate: 0), 1)
        XCTAssertFalse(SpeechRateRule.systemSpeechUsesAccessibilitySettings)
    }

    func testDocumentRolesAndMarkersHaveOneSpokenTreatmentEach() {
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "body"), .read)
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "heading"), .read)
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "caption"), .announce(lead: "Caption."))
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "table"), .replace(notice: "Table skipped."))
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "equation"), .replace(notice: "Equation skipped."))
        for skipped in ["footnote", "reference", "front_matter", "back_matter", "page_header", "page_footer"] {
            XCTAssertEqual(DocumentSpeechRules.treatment(forRole: skipped), .skip, skipped)
        }
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "a_role_added_later"), .read, "unknown roles are read, never lost")

        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "citation"), .silent)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "footnote"), .silent)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "figure_reference"), .readAsPrinted)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "math"), .readAsPrinted)
    }
}
