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

    /// An interruption that ends without "should resume" is why speech stayed paused on return.
    func testAnEndedInterruptionSaysWhetherItResumed() {
        let fields = SpeechSystemPause.interruptionEnded(shouldResume: false)
            .fields(acted: false, appState: "active", lowPowerMode: false)
        XCTAssertEqual(fields["shouldResume"], "false")
        XCTAssertEqual(fields["resumed"], "false")
        XCTAssertNil(fields["paused"])
    }

    func testRouteLossAndResetSayWhetherTheyPaused() {
        XCTAssertEqual(SpeechSystemPause.routeLost.kind, "speech.route_lost")
        XCTAssertEqual(SpeechSystemPause.routeLost.fields(acted: false, appState: "active", lowPowerMode: false)["paused"], "false")
        XCTAssertEqual(SpeechSystemPause.mediaServicesReset.kind, "speech.media_services_reset")
    }
}
