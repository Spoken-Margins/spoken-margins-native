import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// How long an audio file runs, read by decoding its header with the system's audio reader. Used by Add Voice Margin
/// (#4924) to refuse a file that isn't audio, is empty or is too long before anything is kept.
public enum AudioFileLength {
    /// The length in milliseconds, or nil when the file can't be opened as audio or reports no length.
    public static func milliseconds(of url: URL) -> Int? {
        #if canImport(AVFoundation)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Int((Double(file.length) / rate * 1_000).rounded())
        #else
        return nil
        #endif
    }
}
