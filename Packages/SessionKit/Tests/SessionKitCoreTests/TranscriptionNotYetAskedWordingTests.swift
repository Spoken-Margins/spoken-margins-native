import XCTest
@testable import SessionKit

/// #4715 PR 1: a Margin whose transcription only met the hold on iOS's prompt is waiting, not failed.
final class TranscriptionNotYetAskedWordingTests: XCTestCase {
    private let notYetAsked = String(describing: SessionKitError.persistenceFailed("speech_recognition_not_yet_asked"))

    func testTheHoldIsADistinctErrorFromDeclining() {
        XCTAssertEqual(TranscriptionFailureWording.speechRecognitionNotYetAskedError, "speech_recognition_not_yet_asked")
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: notYetAsked))
        XCTAssertFalse(TranscriptionFailureWording.isSpeechRecognitionOff(error: notYetAsked), "waiting is not Speech Recognition off")
        let off = String(describing: SessionKitError.persistenceFailed("speech_recognition_not_authorized"))
        XCTAssertFalse(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: off))
        for other in ["", "network", "speech_recognition_unavailable", "speech_recognition_not_yet"] {
            XCTAssertFalse(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: other), other)
        }
    }

    func testNoBannerForAMarginThatIsOnlyWaiting() {
        XCTAssertNil(TranscriptionFailureWording.notice(error: notYetAsked, isRetry: false))
        XCTAssertNil(TranscriptionFailureWording.notice(error: notYetAsked, isRetry: true))
    }

    func testWaitingMarginReadsNoTranscriptYet() {
        XCTAssertEqual(
            TranscriptionFailureWording.marginStatus(transcriptionStatus: "failed", speechRecognitionOff: false, speechRecognitionNotYetAsked: true),
            "No transcript yet.")
    }

    func testEveryOtherStatusKeepsTodaysWords() {
        let off = "No transcript: Speech Recognition is off. Turn it on in Settings."
        let table: [(String, Bool, Bool, String?)] = [
            ("failed", false, false, TranscriptionFailureWording.transcriptionNeedsRetry),
            ("failed", true, false, off),
            ("failed", true, true, off),
            ("pending", false, true, "Transcribing…"),
            ("pending", false, false, "Transcribing…"),
            ("transcribed", false, true, nil),
            ("complete", false, true, nil),
            ("", false, true, nil)
        ]
        for (status, isOff, waiting, expected) in table {
            XCTAssertEqual(
                TranscriptionFailureWording.marginStatus(transcriptionStatus: status, speechRecognitionOff: isOff, speechRecognitionNotYetAsked: waiting),
                expected, "\(status) off=\(isOff) notYetAsked=\(waiting)")
        }
        XCTAssertEqual(
            TranscriptionFailureWording.marginStatus(transcriptionStatus: "failed", speechRecognitionOff: false),
            TranscriptionFailureWording.transcriptionNeedsRetry, "the new input defaults to today's behaviour")
    }

    func testAttentionLineLeadsWithNoTranscriptYet() {
        XCTAssertEqual(
            TranscriptionFailureWording.marginAttention(
                transcriptionStatus: "failed", speechRecognitionOff: false, speechRecognitionNotYetAsked: true,
                contextUnavailable: true, recordingMissing: false),
            "No transcript yet.", "the context failed for the same reason, so the one line names the cause")
    }

    func testRowOffersNoRetryBesideNoTranscriptYet() {
        let repair = MarginRowRepair.of(
            isWritten: false, speechRecognitionOff: false, speechRecognitionNotYetAsked: true, transcriptionStatus: "failed",
            contextStatus: .unavailable, recordingMissing: false, canRetryTranscription: true,
            contextRetryRunning: false, transcriptionRetryRunning: false)
        XCTAssertEqual(repair, .none)
    }
}
