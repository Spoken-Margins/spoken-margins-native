#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// How long a downloaded media file is, read from the file itself (#4186). It reads the header and never decodes the
/// audio, so a two-hour episode costs about the same as a short one. Runs off the main actor, in the caller's task.
public enum MediaFileLength {
    /// The file's length in milliseconds, or nil when it is indefinite, invalid, not finite, not above zero, or the
    /// file will not open as audio.
    public static func read(fileURL: URL) async -> Int? {
        if let duration = try? await AVURLAsset(url: fileURL).load(.duration), let ms = milliseconds(duration) { return ms }
        // Downloads are stored with an `.audio` extension, which AVURLAsset may not map to a container; the audio
        // file reader finds the format from the bytes instead.
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return milliseconds(CMTime(seconds: Double(file.length) / rate, preferredTimescale: 1_000))
    }

    static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite, time.seconds > 0 else { return nil }
        let ms = Int((time.seconds * 1_000).rounded())
        return ms > 0 ? ms : nil
    }
}
#endif
