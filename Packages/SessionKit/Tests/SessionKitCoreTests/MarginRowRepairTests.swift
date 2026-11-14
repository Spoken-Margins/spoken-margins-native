import XCTest
@testable import SessionKit

/// #3856: a Margins row shows a Retry only beside the status it fixes.
final class MarginRowRepairTests: XCTestCase {
    private func repair(
        written: Bool = false, speechOff: Bool = false, transcription: String = "transcribed", context: AnchorContextStatus? = .ready,
        recordingMissing: Bool = false, canRetryTranscription: Bool = false, contextRunning: Bool = false, transcriptionRunning: Bool = false
    ) -> MarginRowRepair {
        MarginRowRepair.of(
            isWritten: written, speechRecognitionOff: speechOff, transcriptionStatus: transcription, contextStatus: context,
            recordingMissing: recordingMissing, canRetryTranscription: canRetryTranscription,
            contextRetryRunning: contextRunning, transcriptionRetryRunning: transcriptionRunning)
    }

    // MARK: the table

    func testContextNeedsRetryOffersARetryForContext() {
        XCTAssertEqual(repair(context: .unavailable), .retryContext)
    }

    func testTranscriptionNeedsRetryOffersARetryForTranscription() {
        XCTAssertEqual(repair(transcription: "failed", canRetryTranscription: true), .retryTranscription)
    }

    func testAnyOtherStatusOrNoStatusOffersNothing() {
        XCTAssertEqual(repair(), .none, "nothing needs attention")
        XCTAssertEqual(repair(transcription: "pending"), .none, "Transcribing…")
        XCTAssertEqual(repair(recordingMissing: true), .none, "Recording is unavailable")
        XCTAssertEqual(repair(transcription: "queued", context: nil), .none, "Margin needs attention")
        XCTAssertEqual(repair(context: .pending), .none)
    }

    func testAWrittenMarginNeverGetsARetry() {
        XCTAssertEqual(repair(written: true, context: .unavailable), .none)
        XCTAssertEqual(repair(written: true, transcription: "failed", canRetryTranscription: true), .none)
    }

    func testARetryThatIsRunningHidesItsButton() {
        XCTAssertEqual(repair(context: .unavailable, contextRunning: true), .none)
        XCTAssertEqual(repair(transcription: "failed", canRetryTranscription: true, transcriptionRunning: true), .none)
        // A running retry of the other kind does not hide this one.
        XCTAssertEqual(repair(context: .unavailable, transcriptionRunning: true), .retryContext)
        XCTAssertEqual(repair(transcription: "failed", canRetryTranscription: true, contextRunning: true), .retryTranscription)
    }

    func testATranscriptionThatCannotBeRetriedOffersNoRetryEvenWhenItFailed() {
        XCTAssertEqual(repair(transcription: "failed", canRetryTranscription: false), .none, "no recording is kept to transcribe")
    }

    // MARK: the consequences of marginAttention's order

    func testContextUnavailableWithTheRecordingMissingStillOffersContext() {
        XCTAssertEqual(repair(context: .unavailable, recordingMissing: true), .retryContext)
    }

    func testSpeechRecognitionOffWithAFailedTranscriptionOffersNothingBecauseItsTextSaysToTurnItOn() {
        XCTAssertEqual(repair(speechOff: true, transcription: "failed", context: .unavailable, canRetryTranscription: true), .none)
        XCTAssertEqual(repair(speechOff: true, transcription: "failed", canRetryTranscription: true), .none)
    }

    func testSpeechRecognitionOffWithAnotherStatusDoesNotHideTheContextRetry() {
        XCTAssertEqual(repair(speechOff: true, transcription: "transcribed", context: .unavailable), .retryContext)
    }

    func testAMissingRecordingWithAFailedTranscriptionShowsRecordingUnavailableAndNoButton() {
        XCTAssertEqual(repair(transcription: "failed", recordingMissing: true, canRetryTranscription: true), .none)
    }

    func testContextUnavailableWhileTheMarginsOwnTranscriptionIsPendingOffersNothing() {
        XCTAssertEqual(repair(transcription: "pending", context: .unavailable), .none)
        XCTAssertEqual(repair(speechOff: true, transcription: "pending", context: .unavailable), .none)
    }

    // MARK: the button and the words cannot drift apart

    func testWheneverARetryIsOfferedTheStatusTextNamesThatRetry() {
        let statuses = ["pending", "transcribed", "complete", "failed", "queued", ""]
        let contexts: [AnchorContextStatus?] = [nil, .pending, .ready, .unavailable]
        // Every combination of the eight inputs, as one list of cases.
        var cases: [(status: String, context: AnchorContextStatus?, off: Bool, missing: Bool, can: Bool, written: Bool, cRun: Bool, tRun: Bool)] = []
        for status in statuses {
            for context in contexts {
                for flags in 0..<64 {
                    cases.append((status, context, flags & 1 != 0, flags & 2 != 0, flags & 4 != 0, flags & 8 != 0, flags & 16 != 0, flags & 32 != 0))
                }
            }
        }
        var offered = 0
        for c in cases {
            let result = repair(written: c.written, speechOff: c.off, transcription: c.status, context: c.context, recordingMissing: c.missing,
                                canRetryTranscription: c.can, contextRunning: c.cRun, transcriptionRunning: c.tRun)
            let text = TranscriptionFailureWording.marginAttention(
                transcriptionStatus: c.status, speechRecognitionOff: c.off, contextUnavailable: c.context == .unavailable, recordingMissing: c.missing)
            let label = "\(c.status) \(String(describing: c.context)) off:\(c.off) missing:\(c.missing) can:\(c.can) written:\(c.written)"
            switch result {
            case .none: break
            case .retryContext:
                offered += 1
                XCTAssertEqual(text, TranscriptionFailureWording.contextNeedsRetry, label)
                XCTAssertFalse(c.written || c.cRun, label)
            case .retryTranscription:
                offered += 1
                XCTAssertEqual(text, TranscriptionFailureWording.transcriptionNeedsRetry, label)
                XCTAssertTrue(c.can, label)
                XCTAssertFalse(c.written || c.tRun, label)
            }
        }
        XCTAssertGreaterThan(offered, 0, "the sweep must reach both buttons")
    }

    func testTheTwoStatusStringsAreTheOnesTheRowShows() {
        XCTAssertEqual(TranscriptionFailureWording.contextNeedsRetry, "Context needs retry")
        XCTAssertEqual(TranscriptionFailureWording.transcriptionNeedsRetry, "Transcription needs retry")
        XCTAssertEqual(TranscriptionFailureWording.marginStatus(transcriptionStatus: "failed", speechRecognitionOff: false), "Transcription needs retry")
    }

    // MARK: the banner after a context retry

    func testTheBannerAfterAContextRetryReadsTheStoredStatus() {
        XCTAssertEqual(ContextRetryResultWording.message(status: .ready), "Source context recovered.")
        XCTAssertEqual(ContextRetryResultWording.message(status: .unavailable), "No words were found near this Margin.")
        XCTAssertEqual(ContextRetryResultWording.message(status: .pending), "Context retry finished.")
        XCTAssertEqual(ContextRetryResultWording.message(status: nil), "Context retry finished.", "a row that isn't listed is not guessed at")
    }
}
