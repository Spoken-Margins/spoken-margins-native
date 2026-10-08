import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation

/// A recorder for UI-test launches only: instead of the microphone, finishing
/// writes a quiet tone as long as the recording lasted, in the same format and
/// folder as `SystemRecordingClient`. A saved Margin then has a real file to
/// play, before and after a relaunch, with no microphone permission prompt.
public final class UITestingToneRecordingClient: RecordingClient {
    private let supportDirectory: URL
    private let now: () -> Date
    private var startedAt: Date?

    /// `supportDirectory` is Application Support; files go in `SpokenMargins/interjections`.
    public init(supportDirectory: URL, now: @escaping () -> Date = Date.init) {
        self.supportDirectory = supportDirectory
        self.now = now
    }

    public func beginRecording() throws {
        startedAt = now()
    }

    public func finishRecording(audioRef: String?) throws -> String {
        guard let startedAt else {
            if let audioRef { return audioRef }
            throw SessionKitError.invalidCommandForState("finishRecording")
        }
        self.startedAt = nil
        let seconds = min(max(now().timeIntervalSince(startedAt), 1), 120)
        let relativePath = "SpokenMargins/interjections/ui-test-\(UUID().uuidString).m4a"
        let url = supportDirectory.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeTone(to: url, seconds: seconds)
        return relativePath
    }

    public func cancelRecording() throws {
        startedAt = nil
    }

    static func writeTone(to url: URL, seconds: TimeInterval) throws {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SessionKitError.persistenceFailed("ui_test_recording_format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else {
            throw SessionKitError.persistenceFailed("ui_test_recording_buffer")
        }
        for frame in 0..<Int(frames) {
            samples[frame] = Float(0.1 * sin(2 * Double.pi * 330 * Double(frame) / sampleRate))
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
        file.close()
    }
}
#endif

/// Speech recognition for UI-test launches: a fixed transcript for a Margin and
/// no source transcript, so a script never meets the Speech Recognition prompt.
public struct UITestingSourceTranscriptionClient: SourceTranscriptionClient {
    public init() {}

    public func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionOffError)
    }
}

public enum UITestingMarginTranscript {
    public static let text = "A UI test Margin."
}
