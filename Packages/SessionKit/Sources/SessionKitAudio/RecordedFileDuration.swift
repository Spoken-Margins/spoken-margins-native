#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// How much audio a finished recording file really holds (#937).
///
/// A stopped `AVAudioRecorder` reports `currentTime` 0, and a poll can be a quarter of a second old or
/// older. Before anything deletes a recording, its length is read from the finalized file itself.
enum RecordedFileDuration {
    /// Milliseconds of audio in the file, or nil if it can't be opened as audio (empty, still being
    /// written, or not a recording).
    static func milliseconds(of url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Int((Double(file.length) / rate * 1_000).rounded())
    }
}
#endif
