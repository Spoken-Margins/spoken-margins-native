import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class SystemSpeechPlaybackClient: AudioPlaybackClient {
    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    public init() {}

    public func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    public func play(targetId: String) throws {
        #if canImport(AVFoundation)
        _ = synthesizer
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
