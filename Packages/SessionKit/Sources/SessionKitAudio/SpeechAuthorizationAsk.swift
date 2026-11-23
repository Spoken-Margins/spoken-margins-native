import Foundation
import SessionKit
#if canImport(Speech)
import Speech

/// #4715 / #5016: the one gate every transcription client goes through before it asks iOS for Speech Recognition.
///
/// Both clients used to call `SFSpeechRecognizer.requestAuthorization` whenever the answer was still open, which put iOS's
/// prompt in the middle of a first save with nothing from the app before it. Now, while the answer is open and
/// `mayAskSystem()` is false, the client throws `speech_recognition_not_yet_asked` and never calls iOS. The app flips the
/// gate only after the listener taps Yes on its own card, and that handler makes the request itself. One rule covers every
/// caller, so a later one can't bring the surprise back.
///
/// The default is open, so the macOS tools and tests that have no card behave as before; the app closes it at launch.
public enum SpeechAuthorizationAsk {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: @Sendable () -> Bool = { true }
        var current: @Sendable () -> Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private static let gate = Gate()

    private final class HoldSink: @unchecked Sendable {
        private let lock = NSLock()
        private var value: @Sendable (HeldTranscription) -> Void = { _ in }
        var current: @Sendable (HeldTranscription) -> Void {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private static let holdSink = HoldSink()

    /// Where the gate reports each hold, with what the held work was for. The app's speech ask decides from that whether
    /// the card is owed and how the work starts again; no caller has to arm it. Nothing by default (tools and tests).
    public static var reportHold: @Sendable (HeldTranscription) -> Void { holdSink.current }

    public static func setHoldSink(_ sink: @escaping @Sendable (HeldTranscription) -> Void) {
        holdSink.current = sink
    }

    /// Whether iOS may be asked now. True only after the listener's Yes in the app.
    public static var mayAskSystem: @Sendable () -> Bool { gate.current }

    public static func setMayAskSystem(_ decide: @escaping @Sendable () -> Bool) {
        gate.current = decide
    }

    /// iOS's prompt, asked directly. The Yes handler calls this; nothing else should.
    public static func requestFromSystem() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Returns when Speech Recognition is allowed. Throws `speech_recognition_not_yet_asked` when the answer is open and
    /// the app hasn't asked yet, and `speech_recognition_not_authorized` for any decided no. An allowed answer is never held,
    /// so source transcription is not blocked by the ask. `purpose` has no default: every caller says what the work is
    /// for, and a hold is reported with it to `reportHold` before the throw (#4715), so the card is armed at the hold
    /// itself, whichever surface met it.
    public static func requireAuthorized(
        for purpose: HeldTranscription,
        current: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus(),
        mayAskSystem: Bool = SpeechAuthorizationAsk.mayAskSystem(),
        reportHold: @Sendable (HeldTranscription) -> Void = SpeechAuthorizationAsk.reportHold,
        request: () async -> SFSpeechRecognizerAuthorizationStatus = { await SpeechAuthorizationAsk.requestFromSystem() }
    ) async throws {
        var status = current
        if status == .notDetermined, mayAskSystem {
            status = await request()
        }
        switch status {
        case .authorized:
            return
        case .notDetermined:
            reportHold(purpose)
            throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionNotYetAskedError)
        default:
            throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionOffError)
        }
    }
}
#endif
