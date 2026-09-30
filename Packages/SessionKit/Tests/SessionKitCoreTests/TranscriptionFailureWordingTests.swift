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
}
