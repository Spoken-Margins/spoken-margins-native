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

    // #540: a player that stopped making sound hands over to the iOS voice without a tap, and gets another try
    // at the next play instead of waiting for Retry.
    func testAStalledPlayerHandsOverAndTheChosenVoiceGetsAnotherTryAtTheNextPlay() {
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_player_stalled", resourceBlock: nil), .playerStalled)
        XCTAssertEqual(SpeechFallbackReason.playerStalled.rawValue, "player_stalled")
        XCTAssertTrue(SpeechFallbackReason.playerStalled.returnsAutomatically)
        XCTAssertTrue(SpeechEnginePolicy.restoresChosenVoice(after: .playerStalled, conditions: SpeechEngineConditions()))
        XCTAssertFalse(
            SpeechEnginePolicy.restoresChosenVoice(after: .playerStalled, conditions: SpeechEngineConditions(thermal: .serious)),
            "still too warm to render: the iOS voice stays"
        )
        let line = SpeechFallbackReason.playerStalled.listenerExplanation
        XCTAssertTrue(line.contains("stopped playing"), line)
        XCTAssertTrue(line.contains("next time you press play"), line)
        XCTAssertFalse(line.contains("Retry"), "nothing for the listener to do")
    }

    // #1673: narration handed to the iOS voice because the next chunk wasn't rendered with the app in the
    // background says so, and the chosen voice gets another try at the next play.
    func testABackgroundGapHandsOverAndTheChosenVoiceGetsAnotherTryAtTheNextPlay() {
        XCTAssertEqual(SpeechFallbackReason(supertonicCode: "supertonic_background_gap", resourceBlock: nil), .backgroundGap)
        XCTAssertEqual(SpeechFallbackReason.backgroundGap.rawValue, "background_gap")
        XCTAssertTrue(SpeechEnginePolicy.restoresChosenVoice(after: .backgroundGap, conditions: SpeechEngineConditions()))
        XCTAssertFalse(
            SpeechEnginePolicy.restoresChosenVoice(after: .backgroundGap, conditions: SpeechEngineConditions(thermal: .serious)),
            "still too warm to render: the iOS voice stays"
        )
        let line = SpeechFallbackReason.backgroundGap.listenerExplanation
        XCTAssertTrue(line.contains("background"), line)
        XCTAssertTrue(line.contains("next item"), "the stand-in keeps the item (#1786): \(line)")
        XCTAssertFalse(line.contains("next time you press play"), line)
        XCTAssertFalse(line.contains("Retry"), "nothing for the listener to do")
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "background_gap", fallbackReason: nil), line
        )
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

    /// #849 audit (I14): when the app's own backup voice takes over, the line names the cause and never says the
    /// iOS voice is reading, since it isn't.
    func testTheBackupVoiceLineNamesTheCauseAndNeverTheIOSVoice() {
        let all: [SpeechFallbackReason] = [.deviceTooWarm, .memoryWarning, .renderTooSlow, .playbackFailed,
                                           .playerStalled, .backgroundGap, .listenerStoppedGeneration]
        for reason in all {
            let line = reason.bundledVoiceExplanation
            XCTAssertTrue(line.contains("backup voice"), line)
            XCTAssertFalse(line.contains("iOS voice"), line)
            XCTAssertTrue(line.contains("next item"), "the backup voice keeps the item (#1786): \(line)")
            XCTAssertFalse(line.contains("next time you press play"), line)
        }
        XCTAssertTrue(SpeechFallbackReason.deviceTooWarm.listenerExplanation.contains("next item"), "the iOS voice too")
        XCTAssertTrue(SpeechFallbackReason.deviceTooWarm.bundledVoiceExplanation.contains("too warm"))
        XCTAssertTrue(SpeechFallbackReason.memoryWarning.bundledVoiceExplanation.contains("memory warning"))
        XCTAssertFalse(SpeechFallbackReason.deviceTooWarm.bundledVoiceExplanation.contains("Low Power"))
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

        // The stop's own reason decides. The model's fallback reason can be left from another
        // item (#314 audit): A stopped by the listener, B hit a memory warning, back on A.
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "listener_stopped_generation", fallbackReason: .memoryWarning),
            SpeechFallbackReason.listenerStoppedGeneration.listenerExplanation
        )
        XCTAssertFalse(
            SpeechGenerationStopReason.listenerExplanation(stopReason: "supertonic_render_timeout", fallbackReason: .memoryWarning)
                .contains("iOS")
        )
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(stopReason: nil, fallbackReason: .memoryWarning),
            SpeechFallbackReason.memoryWarning.listenerExplanation,
            "Only a stop without a reason falls back to the model's reason"
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
        // Play on an item whose generation is already stopped goes straight to the iOS voice.
        XCTAssertEqual(
            SpeechGenerationStopReason.listenerExplanation(
                stopReason: SpeechGenerationStopReason.generationDisabledCode, fallbackReason: nil
            ),
            "Generation stopped · using the iOS system voice"
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

    /// The one quarter-step rule behind the saved speed, the speed button and the lock-screen speed (#974).
    /// The expected values are written out by hand, not computed from the rule.
    func testQuarterStepMultiplierRoundsToTheNearestQuarterAndStaysInRange() {
        let table: [(input: Double, expected: Double)] = [
            (0.6, 0.5), (0.63, 0.75), (0.625, 0.75), (0.74, 0.75), (0.76, 0.75),
            (1.0, 1.0), (1.1249, 1.0), (1.125, 1.25), (1.4, 1.5), (1.99, 2.0),
            (2.4, 2.0), (9, 2.0), (0.1, 0.5), (0, 0.5), (-1, 0.5)
        ]
        for (input, expected) in table {
            XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(input), expected, "\(input)")
        }
        for step in SpeechRateRule.supportedMultipliers {
            XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(step), step, "a supported speed stays put (\(step))")
        }
    }

    /// NaN agrees with `clampedMultiplier` (1×, #1962); infinities keep what the app did before the
    /// rule moved, so a speed saved by an older build reads back the same.
    func testQuarterStepMultiplierGivesNormalSpeedForNaNAndKeepsTheOldBoundsForInfinities() {
        XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(.nan), 1.0)
        XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(.nan), SpeechRateRule.clampedMultiplier(.nan))
        XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(.infinity), 2.0)
        XCTAssertEqual(SpeechRateRule.quarterStepMultiplier(-.infinity), 0.5)
    }

    func testTheSupportedSpeedsAreQuarterStepsFromHalfToDoubleAndMatchTheSystemRateTable() {
        XCTAssertEqual(SpeechRateRule.supportedMultipliers, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(SpeechRateRule.supportedMultipliers, Array(stride(from: 0.5, through: 2.0, by: 0.25)))
        XCTAssertEqual(SpeechRateRule.supportedMultipliers, SpeechRateRule.systemRateTable.map(\.multiplier))
        XCTAssertEqual(SpeechRateRule.supportedMultipliers.first, SpeechRateRule.multiplierRange.lowerBound)
        XCTAssertEqual(SpeechRateRule.supportedMultipliers.last, SpeechRateRule.multiplierRange.upperBound)
    }

    func testTheSpeedButtonStepsUpAndWrapsFromTheTopToTheBottom() {
        let table: [(current: Double, expected: Double)] = [
            (0.5, 0.75), (0.75, 1), (1, 1.25), (1.5, 1.75), (1.75, 2),
            (2, 0.5), (2.5, 0.5), (9, 0.5),
            (0.25, 0.5), (0, 0.5), (-1, 0.5),
            (1.0004, 1.25), (0.9995, 1.25), (1.1, 1.25), (1.9989, 2)
        ]
        for (current, expected) in table {
            XCTAssertEqual(SpeechRateRule.next(after: current), expected, "after \(current)")
        }
        XCTAssertEqual(SpeechRateRule.next(after: .nan), 0.5, "no step is above NaN, so it wraps")
        XCTAssertEqual(SpeechRateRule.next(after: .infinity), 0.5)
        XCTAssertEqual(SpeechRateRule.next(after: -.infinity), 0.5)

        var speed = SpeechRateRule.supportedMultipliers[0]
        var seen = [speed]
        for _ in 0..<SpeechRateRule.supportedMultipliers.count {
            speed = SpeechRateRule.next(after: speed)
            seen.append(speed)
        }
        XCTAssertEqual(seen, SpeechRateRule.supportedMultipliers + [0.5], "one full lap visits every speed once")
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
