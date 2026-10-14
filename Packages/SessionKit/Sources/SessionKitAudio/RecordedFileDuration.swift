#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

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

/// Whether a recording an unfinished Margin left behind can be used (#951). A file that will not open is not
/// valid, however many bytes it has: a recorder killed mid-write leaves an AAC file without its closing index.
public enum RecordingDraftProbe {
    public static func isDecodable(_ url: URL) -> Bool {
        if case .milliseconds(let ms) = RecordedFileDuration.measure(url) { return ms > 0 }
        return false
    }
}

/// Whether a restart may delete the file of the recorder it replaces (#1041). Pure, so the refusal is testable
/// without a microphone.
enum CaptureRestartGuard {
    enum Verdict: Equatable {
        /// Nothing worth keeping: the file may go.
        case restart
        /// The recorder holds audio worth saving.
        case keepAudio
        /// A stopped recorder's file hasn't been measured yet, or couldn't be: it may hold speech.
        case keepUnknown
    }

    /// `capturedMs` is the most audio the recorder has shown, read just before it stopped when it was running.
    /// `measurement` is the poll's background measurement of a recorder that had already stopped, nil until it lands.
    static func verdict(capturedMs: Int, recorderHadStopped: Bool, measurement: RecordedFileDuration.Outcome?) -> Verdict {
        var captured = capturedMs
        if recorderHadStopped {
            switch measurement {
            case .milliseconds(let fileMs)?: captured = max(captured, fileMs)
            case .unreadable?, nil: return .keepUnknown
            }
        }
        return captured >= MarginCaptureTimings.keepAudioMs ? .keepAudio : .restart
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
