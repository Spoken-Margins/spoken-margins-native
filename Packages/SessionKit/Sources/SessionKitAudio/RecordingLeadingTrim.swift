#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Drops the start of a just-saved recording, where the ready cue (#1594) can have bled in from the speaker.
///
/// The copy is written beside the recording and swapped in only after it is measured. Any failure leaves the
/// recording exactly as it was: a cue left in is better than a Margin lost.
enum RecordingLeadingTrim {
    enum Outcome: Equatable {
        case trimmed(removedMs: Int)
        case skipped(String)

        var diagnosticName: String {
            switch self {
            case .trimmed(let removedMs): return "trimmed:\(removedMs)ms"
            case .skipped(let why): return "skipped:\(why)"
            }
        }
    }

    /// A recording that would keep less than this after the trim is left whole: it is little more than the cue.
    static let minimumKeptMs = 250
    /// How far the kept length may differ from the source length minus the trim (AAC packets and priming).
    static let lengthToleranceMs = 120
    /// About 1.5 s at 44.1 kHz per read, so a Margin of any length is trimmed in the same small memory.
    static let chunkFrames: AVAudioFrameCount = 65_536

    private enum TrimError: Error { case buffer }

    static func trim(url: URL, leadingMs: Int, fileManager: FileManager = .default) -> Outcome {
        guard leadingMs > 0 else { return .skipped("nothing_to_trim") }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".readycue-\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            let sourceMs: Int
            switch RecordedFileDuration.measure(url) {
            case .milliseconds(let ms): sourceMs = ms
            case .unreadable: return .skipped("unreadable")
            }
            guard sourceMs - leadingMs >= minimumKeptMs else { return .skipped("shorter_than_cue") }
            try copy(from: url, droppingMs: leadingMs, to: temporary)
            guard case .milliseconds(let keptMs) = RecordedFileDuration.measure(temporary),
                  abs(keptMs - (sourceMs - leadingMs)) <= lengthToleranceMs else {
                return .skipped("verify_failed")
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            return .trimmed(removedMs: max(0, sourceMs - keptMs))
        } catch {
            return .skipped("error")
        }
    }

    /// Decodes `source` from `droppingMs` on and writes it as AAC, the format the recorder writes.
    private static func copy(from source: URL, droppingMs: Int, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { input.close() }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { throw TrimError.buffer }
        input.framePosition = AVAudioFramePosition((Double(droppingMs) / 1_000 * format.sampleRate).rounded())
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
#endif
