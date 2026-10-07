#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// How much audio a finished recording file really holds (#937).
///
/// A stopped `AVAudioRecorder` reports `currentTime` 0, and a poll can be a quarter of a second old or
/// older. Before anything deletes a recording, its length is read from the finalized file itself.
enum RecordedFileDuration {
    enum Outcome: Equatable, Sendable {
        case milliseconds(Int)
        /// The file exists and has bytes but would not open as audio (still being written, or damaged).
        /// It may hold speech, so callers keep it: unknown is never "empty".
        case unreadable
    }

    /// A missing file or one with no bytes holds nothing to keep. Any other file that will not open is
    /// `unreadable`, not empty.
    static func measure(_ url: URL) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .milliseconds(0) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if size == 0 { return .milliseconds(0) }
        guard let file = try? AVAudioFile(forReading: url) else { return .unreadable }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return .unreadable }
        return .milliseconds(Int((Double(file.length) / rate * 1_000).rounded()))
    }
}

/// A measurement running off the main thread. The poll reads `outcome` and never waits; a result that
/// arrives after the recording ended is dropped with the box.
final class StoppedFileMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecordedFileDuration.Outcome?

    /// Nil while the measurement is still running.
    var outcome: RecordedFileDuration.Outcome? { lock.withLock { stored } }

    static func start(url: URL) -> StoppedFileMeasurement {
        let measurement = StoppedFileMeasurement()
        DispatchQueue.global(qos: .utility).async {
            let result = RecordedFileDuration.measure(url)
            measurement.lock.withLock { measurement.stored = result }
        }
        return measurement
    }
}
#endif
