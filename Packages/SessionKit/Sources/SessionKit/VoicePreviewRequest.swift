import Foundation

/// A voice preview the listener asked for (#2125). Rendering takes seconds, and the listener may press play,
/// start a Margin or pick another voice meanwhile. The preview plays only if it is still the latest one, the
/// voice it rendered is still the one picked, and nothing else is speaking or recording.
public struct VoicePreviewRequest<Voice: Equatable & Sendable>: Sendable {
    private var request = CurrentRequest()
    private var voice: Voice?

    public init() {}

    /// A tap on Preview. An older preview still rendering is stale from now on.
    public mutating func begin(voice: Voice) -> CurrentRequest.Token {
        self.voice = voice
        return request.begin()
    }

    /// Playback started, a Margin started or the voice changed: the preview still rendering must not play.
    public mutating func cancel() {
        request.cancel()
        voice = nil
    }

    /// Whether a preview is still rendering and would play.
    public var isPending: Bool { request.isPending }

    /// After the render: true when the preview may play now. A stale token, another voice or other audio means
    /// no; the request is consumed either way, so a preview plays at most once.
    public mutating func mayPlay(_ token: CurrentRequest.Token, selectedVoice: Voice?, otherAudioActive: Bool) -> Bool {
        let renderedVoice = voice
        guard request.finish(token) else { return false }
        voice = nil
        return selectedVoice == renderedVoice && !otherAudioActive
    }
}
