import Speech

/// Whether the listener has Speech Recognition turned off for the app (#268).
/// Read at display time, so a Margin's status follows the setting when it changes.
enum SpeechRecognitionAccess {
    static var isOff: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: true
        default: false
        }
    }
}
