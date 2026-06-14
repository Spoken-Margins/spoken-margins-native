import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class SystemSpeechPlaybackClient: AudioPlaybackClient {
    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif
    private var preparedSpeechText = ""

    public init() {}

    public func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        preparedSpeechText = normalized
        return normalized
    }

    public func play(targetId: String) throws {
        #if canImport(AVFoundation)
        guard !preparedSpeechText.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.continueSpeaking()
            return
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: preparedSpeechText)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
        #endif
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        synthesizer.pauseSpeaking(at: .word)
        #endif
    }
}

public final class SystemRecordingClient: RecordingClient {
    public init() {}
    public func beginRecording() throws {}
    public func finishRecording(audioRef: String?) throws -> String {
        audioRef ?? "interjections/system-recording.m4a"
    }
    public func cancelRecording() throws {}
}
