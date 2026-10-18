import Foundation

public enum Gate2CompactCommandURL {
    #if SPOKEN_MARGINS_LEGACY
    public static let scheme = "spokenmargins-legacy"
    #else
    public static let scheme = "spokenmargins"
    #endif
    public static let host = "compact-control"

    public static func url(command: String, chapterId: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "command", value: command)]
        if let chapterId, !chapterId.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "chapterId", value: chapterId))
        }
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func command(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "command" })?
            .value
    }

    public static func chapterId(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "chapterId" })?
            .value
    }
}

// Where a tap on the Live Activity goes. Kept here, not with the attributes, because the share extension compiles
// the attributes file without the command URL.
extension Gate2LiveActivityAttributes.ContentState {
    /// Paused and not recording, or past its stale date (the app sets one only while paused).
    /// The card then says how to resume instead of looking like a frozen player.
    func offersResume(isStale: Bool) -> Bool {
        guard !isRecording, sharedMarginSenderLabel == nil else { return false }
        return isStale || status == "paused"
    }

    /// What the state images and the "PLAY" word say to VoiceOver: the state in words (#1913).
    func stateAccessibilityLabel(isStale: Bool) -> String {
        if sharedMarginSenderLabel != nil { return Gate2LiveActivityAccessibility.sharedMarginIcon }
        if isRecording {
            switch microphone {
            case .capturing: return "Recording a Margin"
            case .starting: return "Starting the microphone"
            case .stopped: return "Microphone stopped"
            }
        }
        if offersResume(isStale: isStale) { return "Paused, tap to resume" }
        if isLoadingAudio { return "Loading" }
        return isAudioRunning ? "Playing" : status.capitalized
    }

    /// Where a tap on the card goes. A paused card opens the app and resumes. A card that is playing opens the
    /// playback screen of what is sounding, instead of leaving the app on whatever screen it was last on (#1337).
    /// A recording card, or one showing a friend's Margin, just opens the app.
    func tapURL(isStale: Bool) -> URL? {
        if offersResume(isStale: isStale) { return Gate2CompactCommandURL.url(command: "play") }
        guard !isRecording, sharedMarginSenderLabel == nil else { return nil }
        return Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback)
    }
}
