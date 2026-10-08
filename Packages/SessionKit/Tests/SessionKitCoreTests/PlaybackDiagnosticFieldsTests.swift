import XCTest
@testable import SessionKit

/// #1109: the playback records name who paused narration and when it fell back to the iOS voice.
/// The #1101 export showed `status=paused` and a "device_too_warm" fallback on a phone that read nominal,
/// and nothing in the log said what acted.
final class PlaybackDiagnosticFieldsTests: XCTestCase {
    func testNarrationFieldsNameTheClientsIntentAndVoice() {
        XCTAssertEqual(
            PlaybackDiagnosticFields.narration(intent: "paused", systemVoiceActive: false, standInPassage: false),
            ["clientIntent": "paused", "clientVoice": "on_device", "clientStandIn": "false"]
        )
        XCTAssertEqual(
            PlaybackDiagnosticFields.narration(intent: "playing", systemVoiceActive: true, standInPassage: false),
            ["clientIntent": "playing", "clientVoice": "system_voice", "clientStandIn": "false"]
        )
    }

    /// A short passage the iOS voice read plays through the on-device player: the voice flag alone would
    /// say on_device while the listener hears the iOS voice.
    func testAStandInPassageIsNamedEvenThoughTheOnDevicePlayerPlaysIt() {
        XCTAssertEqual(
            PlaybackDiagnosticFields.narration(intent: "playing", systemVoiceActive: false, standInPassage: true),
            ["clientIntent": "playing", "clientVoice": "on_device", "clientStandIn": "true"]
        )
    }

    /// The owner's #1101 export: a render was refused, and by the time the fallback was recorded the policy
    /// read nominal. The reason shown is the default, and the record has to say so.
    func testAFallbackWithNothingRefusingRenderingNowIsMarkedAsDefaultedNotMeasured() {
        let conditions = SpeechEngineConditions(thermal: .nominal)
        let block = SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
        let reason = SpeechFallbackReason(supertonicCode: "supertonic_resource_pressure", resourceBlock: block)
        let fields = PlaybackDiagnosticFields.supertonicFallback(
            code: "supertonic_resource_pressure", reason: reason, policyBlock: block, conditions: conditions, offset: 8_344
        )
        XCTAssertEqual(fields["reason"], "device_too_warm")
        XCTAssertEqual(fields["policyBlock"], "none", "no resource refused rendering when this was recorded")
        XCTAssertEqual(fields["code"], "supertonic_resource_pressure")
        XCTAssertEqual(fields["offset"], "8344")
        XCTAssertEqual(fields["conditions"], "thermal=nominal lowPower=false power=unknown memoryBackoff=false")
    }

    func testAFallbackForAMeasuredHeatReadingKeepsTheReadingBesideTheReason() {
        let conditions = SpeechEngineConditions(thermal: .serious, isOnExternalPower: true)
        let block = SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
        let fields = PlaybackDiagnosticFields.supertonicFallback(
            code: "supertonic_resource_pressure",
            reason: SpeechFallbackReason(supertonicCode: "supertonic_resource_pressure", resourceBlock: block),
            policyBlock: block, conditions: conditions, offset: 0
        )
        XCTAssertEqual(fields["reason"], "device_too_warm")
        XCTAssertEqual(fields["policyBlock"], "device_too_warm")
        XCTAssertEqual(fields["conditions"], "thermal=serious lowPower=false power=external memoryBackoff=false")
    }

    func testAMemoryBackoffFallbackIsNamedAsMemory() {
        let conditions = SpeechEngineConditions(isRecoveringFromMemoryWarning: true)
        let block = SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
        let fields = PlaybackDiagnosticFields.supertonicFallback(
            code: "supertonic_resource_pressure",
            reason: SpeechFallbackReason(supertonicCode: "supertonic_resource_pressure", resourceBlock: block),
            policyBlock: block, conditions: conditions, offset: 12
        )
        XCTAssertEqual(fields["reason"], "memory_warning")
        XCTAssertEqual(fields["policyBlock"], "memory_warning")
    }

    func testOtherFallbackCodesKeepTheirCodeAndNeverClaimHeat() {
        let conditions = SpeechEngineConditions()
        let fields = PlaybackDiagnosticFields.supertonicFallback(
            code: "supertonic_render_timeout",
            reason: SpeechFallbackReason(supertonicCode: "supertonic_render_timeout", resourceBlock: nil),
            policyBlock: nil, conditions: conditions, offset: 3
        )
        XCTAssertEqual(fields["code"], "supertonic_render_timeout")
        XCTAssertEqual(fields["reason"], "render_too_slow")
        XCTAssertEqual(fields["policyBlock"], "none")
    }

    func testTheFieldsCarryOnlyStateTokensAndCounters() {
        let keys = Set(PlaybackDiagnosticFields.supertonicFallback(
            code: "c", reason: .playbackFailed, policyBlock: nil, conditions: SpeechEngineConditions(), offset: 0
        ).keys).union(PlaybackDiagnosticFields.narration(intent: "stopped", systemVoiceActive: false, standInPassage: false).keys)
        XCTAssertEqual(keys, ["code", "reason", "policyBlock", "conditions", "offset", "clientIntent", "clientVoice", "clientStandIn"])
    }
}
