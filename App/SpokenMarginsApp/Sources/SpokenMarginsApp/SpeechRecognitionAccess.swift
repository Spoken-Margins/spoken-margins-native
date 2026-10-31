import Speech

/// Whether the listener has Speech Recognition turned off for the app (#268).
/// Read at display time, so a Margin's status follows the setting when it changes.
enum SpeechRecognitionAccess {
    /// Where the status comes from. Tests replace it; the app never does.
    nonisolated(unsafe) static var statusProvider: () -> SFSpeechRecognizerAuthorizationStatus = {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var isOff: Bool {
        switch statusProvider() {
        case .denied, .restricted: true
        default: false
        }
    }

    /// Already allowed, with no question to ask. Background work that must not interrupt the listener checks this
    /// instead of calling the transcriber, whose own authorization step shows iOS's prompt when the answer is still
    /// open (#2966: the "Just heard" peek runs while the microphone is live).
    static var isAuthorized: Bool { statusProvider() == .authorized }
}
