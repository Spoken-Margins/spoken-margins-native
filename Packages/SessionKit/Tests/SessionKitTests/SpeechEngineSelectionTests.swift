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

    /// #314: a stop keeps its reason. Before, an assembly failure read as "using the iOS system
    /// voice", which was wrong: playback never left the on-device voice.
    func testEveryGenerationStopSaysWhyAndAnAssemblyFailureKeepsItsError() {
        struct DiskFull: Error {}
        let reason = SpeechGenerationStopReason.assemblyFailed(DiskFull())
        XCTAssertEqual(reason, "prepared_audio_assembly_failed: DiskFull()")

        let assembly = SpeechGenerationStopReason.listenerExplanation(stopReason: reason, fallbackReason: nil)
        XCTAssertTrue(assembly.contains("Couldn't save the finished audio"), assembly)
        XCTAssertFalse(assembly.contains("iOS system voice"), assembly)
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: reason, fallbackReason: .deviceTooWarm),
            assembly
        )

        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "supertonic_render_timeout", fallbackReason: .memoryWarning),
            SpeechFallbackReason.memoryWarning.listenerExplanation
        )
        // A render failure the iOS voice didn't take over from arrives without a fallback reason.
        // The line says why preparing stopped and never claims the iOS voice is playing.
        for code in ["supertonic_render_timeout", "supertonic_resource_pressure", "supertonic_render_failed:SomeError"] {
            let line = SpeechGenerationStopReason.listenerExplanation(stopReason: code, fallbackReason: nil)
            XCTAssertFalse(line.contains("iOS"), "\(code): \(line)")
            XCTAssertTrue(line.contains("Retry"), "\(code): \(line)")
        }
        XCTAssertTrue(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "supertonic_render_timeout", fallbackReason: nil)
                .contains("couldn't keep up")
        )
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "memory_warning", fallbackReason: nil),
            SpeechFallbackReason.memoryWarning.listenerExplanation
        )
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: nil, fallbackReason: nil),
            "Generation stopped · using the iOS system voice"
        )
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

    /// Mirrors the published I14 table on next (docs/workstreams/interfaces.md, #218).
    func testDocumentRolesFollowThePublishedI14Table() {
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "body"), .read)
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "heading"), .readWithPauses(before: 0.7, after: 0.4))
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "caption"), .announceLabelThenRead)
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "table"), .announceAndSkip(notice: "Table not read."))
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "reference"), .skipWithNoticeOnce(notice: "References skipped."))
        // Roles settled in #226.
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "authors"), .read)
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "back_matter"), .skipWithNoticeOnce(notice: "Back matter skipped."))
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "equation"), .skipWithNoticeOnce(notice: "Equation."))
        for skipped in ["footnote", "front_matter", "page_header", "page_footer"] {
            XCTAssertEqual(DocumentSpeechRules.treatment(forRole: skipped), .skip, skipped)
        }
        XCTAssertEqual(DocumentSpeechRules.treatment(forRole: "a_role_added_later"), .read, "unknown roles are read, never lost")
    }

    func testOnlyHeadersFootersFootnotesAndFrontMatterAreEverSilent() {
        let roles = ["title", "authors", "heading", "abstract", "body", "caption", "table", "footnote", "equation", "reference",
                     "front_matter", "back_matter", "page_header", "page_footer", "unknown"]
        let silent = roles.filter { DocumentSpeechRules.treatment(forRole: $0) == .skip }
        XCTAssertEqual(Set(silent), ["footnote", "front_matter", "page_header", "page_footer"])
    }

    func testCitationAndFootnoteMarkersAreSilentAndOtherMarkersRead() {
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "citation"), .silent)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "footnote"), .silent)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "figure_reference"), .readAsPrinted)
        XCTAssertEqual(DocumentSpeechRules.treatment(forMarker: "math"), .readAsPrinted)
    }
}
