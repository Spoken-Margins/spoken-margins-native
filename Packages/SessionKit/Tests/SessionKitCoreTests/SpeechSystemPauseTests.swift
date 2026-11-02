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
        let fields = SpeechSystemPause.interruptionEnded(.audioMayStart)
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

    func testAResumeThatReturnsStartingIsLoggedOnlyOnceItPlays() {
        var watch = SpeechInterruptionResumeWatch()
        XCTAssertNil(watch.resumeReturned(Self.snapshot(.starting)), "a starting resume hasn't resumed yet")
        XCTAssertNil(watch.snapshotChanged(Self.snapshot(.starting)))
        XCTAssertEqual(watch.snapshotChanged(Self.snapshot(.playing)), .resumed)
        XCTAssertNil(watch.snapshotChanged(Self.snapshot(.paused)), "settled once, logged once")
    }

    func testAStartingResumeThatFailsIsLoggedAsFailed() {
        var watch = SpeechInterruptionResumeWatch()
        XCTAssertNil(watch.resumeReturned(Self.snapshot(.starting)))
        var failed = Self.snapshot(.failed)
        failed.lastFailure = "render failed"
        XCTAssertEqual(watch.snapshotChanged(failed), .failed(reason: "render failed"))
    }

    func testAResumeThatReturnsFailedWithoutThrowingIsNotResumed() {
        var watch = SpeechInterruptionResumeWatch()
        XCTAssertEqual(watch.resumeReturned(Self.snapshot(.failed)), .failed(reason: "playback_failed"))
        XCTAssertEqual(watch.resumeReturned(Self.snapshot(.paused)), .failed(reason: "ended_paused"))
        XCTAssertEqual(watch.resumeReturned(Self.snapshot(.playing)), .resumed)
    }

    func testAStartingResumeReplacedByAnotherSessionIsNotResumed() {
        var watch = SpeechInterruptionResumeWatch()
        XCTAssertNil(watch.resumeReturned(Self.snapshot(.starting)))
        XCTAssertEqual(watch.snapshotChanged(Self.snapshot(.playing, sessionId: "other")),
                       .failed(reason: "replaced_before_start"))
    }

    private static func snapshot(_ status: PlaybackStatus, sessionId: String = "s1") -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = sessionId
        snapshot.status = status
        return snapshot
    }
}
