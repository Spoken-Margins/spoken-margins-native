import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Takes the spoken end phrase ("stop margin") off a saved Margin's audio and words (#3940, PR 2 of the Design).
///
/// The cut point comes from the saved file's own aligned transcript, so there is no live-to-file time mapping to
/// keep. It happens only when that transcript's last words are the phrase and its text agrees (`MarginEndPhrase.cut`);
/// in every other case, and in every failure, the original file and words are left exactly as they were: losing the
/// listener's words is worse than keeping two spoken ones.
public enum MarginEndPhraseTrim {
    public enum Outcome: Sendable, Equatable {
        /// Nothing was changed.
        case keepAll
        /// The file at the same path now ends before the phrase, and `transcript` is the words without it.
        case trimmed(transcript: AlignedInterjectionTranscript, durationMs: Int)
    }

    /// How far the trimmed file's length may differ from the cut point before it is not trusted.
    static let durationToleranceMs = 300

    /// The words without the phrase and where to cut, or nil to keep all. Pure; the audio is cut by `trim`.
    static func plan(for transcript: AlignedInterjectionTranscript) -> (cut: MarginEndPhraseCut, kept: AlignedInterjectionTranscript)? {
        let heard = transcript.segments.map { MarginEndPhraseWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) }
        guard let cut = MarginEndPhrase.cut(text: transcript.text, words: heard), cut.keptWordCount > 0,
              cut.keptWordCount < transcript.segments.count else { return nil }
        let kept = AlignedInterjectionTranscript(
            schemaVersion: transcript.schemaVersion,
            text: cut.text,
            localeIdentifier: transcript.localeIdentifier,
            segments: Array(transcript.segments.prefix(cut.keptWordCount))
        )
        return (cut, kept)
    }

    /// Cuts `fileURL` before the phrase and replaces it in place. Any failure leaves the original untouched.
    public static func trim(fileURL: URL, transcript: AlignedInterjectionTranscript) async -> Outcome {
        #if canImport(AVFoundation)
        guard let cutPlan = plan(for: transcript) else { return .keepAll }
        let fileManager = FileManager.default
        // Beside the original, so replacing it is one rename on the same volume.
        let temporary = fileURL.deletingLastPathComponent()
            .appending(path: ".trim-\(UUID().uuidString).m4a")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            let asset = AVURLAsset(url: fileURL)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                return .keepAll
            }
            exporter.outputURL = temporary
            exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: Double(cutPlan.cut.cutAtMs) / 1_000, preferredTimescale: 600)
            )
            try await exporter.export(to: temporary, as: .m4a)
            guard case .milliseconds(let trimmedMs) = RecordedFileDuration.measure(temporary),
                  trimmedMs > 0, abs(trimmedMs - cutPlan.cut.cutAtMs) <= durationToleranceMs else {
                return .keepAll
            }
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            return .trimmed(transcript: cutPlan.kept, durationMs: trimmedMs)
        } catch {
            return .keepAll
        }
        #else
        return .keepAll
        #endif
    }
}
