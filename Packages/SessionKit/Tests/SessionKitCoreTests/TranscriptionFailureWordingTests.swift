import XCTest
@testable import SessionKit

/// #268: declining Speech Recognition read as "Audio saved. Transcript failed.", which sounds
/// like the app broke. The listener chose it, so the words say why and how to turn it on.
final class TranscriptionFailureWordingTests: XCTestCase {
    /// What the app model passes in: `String(describing:)` of the error the adapter throws.
    private let speechRecognitionOff = String(
        describing: SessionKitError.persistenceFailed("speech_recognition_not_authorized")
    )

    func testDeclinedSpeechRecognitionNamesItAndHowToTurnItOn() {
        let notice = TranscriptionFailureWording.notice(error: speechRecognitionOff, isRetry: false)

        XCTAssertFalse(notice.isFailure, "Declining a permission isn't an app failure")
        XCTAssertTrue(notice.message.contains("Audio saved"))
        XCTAssertTrue(notice.message.contains("Speech Recognition is off"))
        XCTAssertTrue(notice.message.contains("Settings"))
        XCTAssertFalse(notice.message.lowercased().contains("fail"))
    }

    func testRetryWithSpeechRecognitionOffSaysTheSame() {
        let notice = TranscriptionFailureWording.notice(error: speechRecognitionOff, isRetry: true)

        XCTAssertFalse(notice.isFailure)
        XCTAssertTrue(notice.message.contains("Speech Recognition is off"))
        XCTAssertTrue(notice.message.contains("Settings"))
        XCTAssertFalse(notice.message.lowercased().contains("fail"))
    }

    func testOtherTranscriptionErrorsStillReportAFailure() {
        let error = String(describing: SessionKitError.persistenceFailed("speech_recognition_unavailable"))

        XCTAssertEqual(
            TranscriptionFailureWording.notice(error: error, isRetry: false),
            .init(message: "Audio saved. Transcript failed.", isFailure: true)
        )
        XCTAssertEqual(
            TranscriptionFailureWording.notice(error: error, isRetry: true),
            .init(message: "Saved audio and current transcript kept. Retranscription failed.", isFailure: true)
        )
    }

    func testNoticeGoesToTheMatchingReporter() {
        var warnings: [String] = []
        var failures: [String] = []

        TranscriptionFailureWording.notice(error: speechRecognitionOff, isRetry: false)
            .present(warning: { warnings.append($0) }, failure: { failures.append($0) })
        TranscriptionFailureWording.notice(error: "network", isRetry: false)
            .present(warning: { warnings.append($0) }, failure: { failures.append($0) })

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(failures, ["Audio saved. Transcript failed."])
    }

    func testMarginStatusNamesSpeechRecognitionWhileItIsOff() throws {
        let status = try XCTUnwrap(
            TranscriptionFailureWording.marginStatus(transcriptionStatus: "failed", speechRecognitionOff: true)
        )

        XCTAssertTrue(status.contains("Speech Recognition is off"))
        XCTAssertTrue(status.contains("Settings"))
        XCTAssertFalse(status.lowercased().contains("fail"))
    }

    func testMarginStatusOffersRetryOnceSpeechRecognitionIsOn() {
        XCTAssertEqual(
            TranscriptionFailureWording.marginStatus(transcriptionStatus: "failed", speechRecognitionOff: false),
            "Transcription needs retry"
        )
        XCTAssertEqual(
            TranscriptionFailureWording.marginStatus(transcriptionStatus: "pending", speechRecognitionOff: true),
            "Transcription is pending"
        )
        XCTAssertNil(TranscriptionFailureWording.marginStatus(transcriptionStatus: "transcribed", speechRecognitionOff: true))
    }

    /// Codex audit on #439: with Speech Recognition off, the source window can't be transcribed
    /// either, so the context fails too. "Context needs retry" hid the actual reason.
    func testSpeechRecognitionOffOutranksTheContextItAlsoBroke() {
        let status = TranscriptionFailureWording.marginAttention(
            transcriptionStatus: "failed",
            speechRecognitionOff: true,
            contextUnavailable: true,
            recordingMissing: false
        )

        XCTAssertTrue(status.contains("Speech Recognition is off"), status)
    }

    func testMarginAttentionKeepsTheOtherReasonsInOrder() {
        func attention(_ status: String, off: Bool = false, context: Bool = false, missing: Bool = false) -> String {
            TranscriptionFailureWording.marginAttention(
                transcriptionStatus: status, speechRecognitionOff: off,
                contextUnavailable: context, recordingMissing: missing
            )
        }

        XCTAssertEqual(attention("failed", context: true), "Context needs retry")
        XCTAssertEqual(attention("pending", off: true, context: true), "Context needs retry")
        XCTAssertEqual(attention("complete", context: true, missing: true), "Context needs retry")
        XCTAssertEqual(attention("complete", missing: true), "Recording is unavailable")
        XCTAssertEqual(attention("failed"), "Transcription needs retry")
        XCTAssertEqual(attention("pending"), "Transcription is pending")
        XCTAssertEqual(attention("complete"), "Margin needs attention")
    }
}
