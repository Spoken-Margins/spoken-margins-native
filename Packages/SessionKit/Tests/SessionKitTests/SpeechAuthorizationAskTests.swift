#if canImport(Speech)
import Speech
import XCTest
import SessionKit
@testable import SessionKitAudio

/// #4715 PR 1 / #5016: both transcription clients ask iOS for Speech Recognition whenever the answer is open, which is
/// the surprise prompt on a first save. They now go through one gate that only asks after the listener's Yes.
final class SpeechAuthorizationAskTests: XCTestCase {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func record() { lock.withLock { calls += 1 } }
    }

    private func outcome(
        current: SFSpeechRecognizerAuthorizationStatus, mayAsk: Bool, answer: SFSpeechRecognizerAuthorizationStatus = .authorized
    ) async -> (error: String?, requests: Int) {
        let requests = Requests()
        do {
            try await SpeechAuthorizationAsk.requireAuthorized(current: current, mayAskSystem: mayAsk) {
                requests.record()
                return answer
            }
            return (nil, requests.count)
        } catch {
            return (String(describing: error), requests.count)
        }
    }

    /// `heldWhileUnanswered`
    func testHeldWhileUnanswered() async {
        let result = await outcome(current: .notDetermined, mayAsk: false)
        XCTAssertEqual(result.requests, 0, "iOS's prompt must not be requested before the listener's Yes")
        XCTAssertEqual(
            result.error,
            String(describing: SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionNotYetAskedError)))
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: result.error ?? ""))
        XCTAssertFalse(TranscriptionFailureWording.isSpeechRecognitionOff(error: result.error ?? ""))
    }

    func testAfterYesTheSystemIsAskedOnceAndItsAnswerDecides() async {
        let allow = await outcome(current: .notDetermined, mayAsk: true, answer: .authorized)
        XCTAssertEqual(allow.requests, 1)
        XCTAssertNil(allow.error)

        let deny = await outcome(current: .notDetermined, mayAsk: true, answer: .denied)
        XCTAssertEqual(deny.requests, 1)
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionOff(error: deny.error ?? ""))
    }

    /// Neighbouring inputs: a decided answer is never re-requested, with the gate open or shut.
    func testADecidedAnswerNeverRequestsAnything() async {
        let table: [(SFSpeechRecognizerAuthorizationStatus, Bool, expectsError: Bool)] = [
            (.authorized, false, false), (.authorized, true, false),
            (.denied, false, true), (.denied, true, true),
            (.restricted, false, true), (.restricted, true, true)
        ]
        for (status, mayAsk, expectsError) in table {
            let result = await outcome(current: status, mayAsk: mayAsk)
            XCTAssertEqual(result.requests, 0, "\(status.rawValue) mayAsk=\(mayAsk)")
            XCTAssertEqual(result.error != nil, expectsError, "\(status.rawValue) mayAsk=\(mayAsk)")
            if let error = result.error {
                XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionOff(error: error), "a decided no is today's wording")
            }
        }
    }

    private func sourceOutcome(
        item: String, current: SFSpeechRecognizerAuthorizationStatus, mayAsk: Bool
    ) async -> String? {
        do {
            try await SpeechAuthorizationAsk.requireAuthorized(forSourceItem: item, current: current, mayAskSystem: mayAsk) { .authorized }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// An imported podcast's placement that met the hold has no Margin to wait on the list, so the gate remembers the
    /// episode and hands it back on Allow; the app then places it again (#4715). iOS already allowing is never held.
    func testASourceTranscriptionThatMetTheHoldIsRememberedOnceAndHandedBackOnce() async {
        _ = SpeechAuthorizationAsk.takeHeldSourceItems()
        let allowed = await sourceOutcome(item: "ep-allowed", current: .authorized, mayAsk: false)
        XCTAssertNil(allowed, "iOS already authorizes: source transcription is not blocked by the ask")
        for denied in [SFSpeechRecognizerAuthorizationStatus.denied, .restricted] {
            let error = await sourceOutcome(item: "ep-denied", current: denied, mayAsk: false)
            XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionOff(error: error ?? ""))
        }
        XCTAssertEqual(SpeechAuthorizationAsk.takeHeldSourceItems(), [], "only the open-and-unasked case is held")

        let first = await sourceOutcome(item: "ep-1", current: .notDetermined, mayAsk: false)
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: first ?? ""))
        _ = await sourceOutcome(item: "ep-2", current: .notDetermined, mayAsk: false)
        _ = await sourceOutcome(item: "ep-1", current: .notDetermined, mayAsk: false)
        XCTAssertEqual(SpeechAuthorizationAsk.takeHeldSourceItems(), ["ep-1", "ep-2"], "oldest first, no repeats")
        XCTAssertEqual(SpeechAuthorizationAsk.takeHeldSourceItems(), [], "handed back once")
    }

    /// Nothing in this process closes the gate, so a macOS tool or test that has no card still asks iOS as it always did.
    func testTheGateIsOpenUntilTheAppClosesIt() {
        XCTAssertTrue(SpeechAuthorizationAsk.mayAskSystem())
    }
}
#endif
