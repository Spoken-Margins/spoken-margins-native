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

    /// Episodes whose source transcription met the hold. Placement of an imported podcast Margin and the episode map both
    /// transcribe the listener's copy with no Margin on the waiting list, so this is how the app knows what to start again
    /// when the listener allows. In memory only: a relaunch places the episode again on its own.
    private final class HeldSources: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { if !ids.contains(id) { ids.append(id) } } }
        func take() -> [String] { lock.withLock { defer { ids.removeAll() }; return ids } }
    }

    private static let gate = Gate()
    private static let heldSources = HeldSources()

    /// The episodes held since the last call, oldest first, each once. The app calls it when iOS has decided: on Allow it
    /// places them again, on a no it drops them.
    public static func takeHeldSourceItems() -> [String] { heldSources.take() }

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
    /// so source transcription is not blocked by the ask. `sourceItemId` names the episode a source transcription is for, so
    /// the app can place it again after Allow.
    public static func requireAuthorized(
        forSourceItem sourceItemId: String? = nil,
        current: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus(),
        mayAskSystem: Bool = SpeechAuthorizationAsk.mayAskSystem(),
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
            if let sourceItemId, !sourceItemId.isEmpty { heldSources.add(sourceItemId) }
            throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionNotYetAskedError)
        default:
            throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionOffError)
        }
    }
}
#endif
