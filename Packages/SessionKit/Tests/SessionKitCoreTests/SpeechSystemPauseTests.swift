import XCTest
@testable import SessionKit

/// #538: the owner's export showed speech "paused" when he left the app, with nothing saying why.
final class SpeechSystemPauseTests: XCTestCase {
    func testAnInterruptionNamesItsReasonAndTheAppState() {
        let pause = SpeechSystemPause.interruptionBegan(reasonRawValue: 1)
        XCTAssertEqual(pause.kind, "speech.interruption_began")
        XCTAssertEqual(pause.fields(acted: true, appState: "background", lowPowerMode: true), [
            "reason": "app_was_suspended", "paused": "true", "appState": "background", "lowPowerMode": "true",
        ])
    }

    func testReasonNamesKeepUnknownValues() {
        XCTAssertEqual(SpeechSystemPause.interruptionReasonName(nil), "none")
        XCTAssertEqual(SpeechSystemPause.interruptionReasonName(0), "default")
        XCTAssertEqual(SpeechSystemPause.interruptionReasonName(2), "built_in_mic_muted")
        XCTAssertEqual(SpeechSystemPause.interruptionReasonName(4), "route_disconnected")
        XCTAssertEqual(SpeechSystemPause.interruptionReasonName(9), "raw_9")
    }

    /// An interruption that ends without "should resume" is why speech stayed paused on return. The
    /// ended event only asks for a resume; whether one happened is its own entry, because the resume
    /// can still fail to start the audio session (Codex audit on 3fddef3).
    func testAnEndedInterruptionSaysWhetherItAskedToResume() {
        let fields = SpeechSystemPause.interruptionEnded(shouldResume: true)
            .fields(acted: true, appState: "active", lowPowerMode: false)
        XCTAssertEqual(fields["shouldResume"], "true")
        XCTAssertEqual(fields["resumeRequested"], "true")
        XCTAssertNil(fields["resumed"], "the request isn't the outcome")
        XCTAssertNil(fields["paused"])
    }

    func testTheResumeOutcomeIsItsOwnEntry() {
        XCTAssertEqual(SpeechInterruptionResume.resumed.kind, "speech.interruption_resume")
        XCTAssertEqual(SpeechInterruptionResume.resumed.fields, ["outcome": "resumed"])
        XCTAssertEqual(SpeechInterruptionResume.skipped.fields, ["outcome": "skipped"])
        XCTAssertEqual(SpeechInterruptionResume.failed(reason: "session busy").fields,
                       ["outcome": "failed", "error": "session busy"])
        XCTAssertEqual(SpeechInterruptionResume.failed(reason: "session busy").diagnostic, "resume_failed:session busy")
        XCTAssertEqual(SpeechInterruptionResume.skipped.diagnostic, "resume_skipped")
        XCTAssertEqual(SpeechInterruptionResume.resumed.diagnostic, "resumed")
    }

    func testRouteLossAndResetSayWhetherTheyPaused() {
        XCTAssertEqual(SpeechSystemPause.routeLost.kind, "speech.route_lost")
        XCTAssertEqual(SpeechSystemPause.routeLost.fields(acted: false, appState: "active", lowPowerMode: false)["paused"], "false")
        XCTAssertEqual(SpeechSystemPause.mediaServicesReset.kind, "speech.media_services_reset")
    }
}
