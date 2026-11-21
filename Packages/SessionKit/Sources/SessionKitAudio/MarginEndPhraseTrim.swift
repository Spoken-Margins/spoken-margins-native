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
///
/// Two steps, so the caller can order them with its own write: `prepare` cuts a copy beside the original and changes
/// nothing; `commit` swaps it in. The caller saves the words without the phrase between the two, so a failed save
/// leaves the audio and the words as they were, and the one failure left (the swap) keeps more of the listener's
/// speech than the saved words show, never less.
public enum MarginEndPhraseTrim {
    /// A cut copy of the file, verified, waiting to replace the original.
    public final class Prepared: @unchecked Sendable {
        /// The words without the phrase, aligned.
        public let transcript: AlignedInterjectionTranscript
        /// The length of the cut file.
        public let durationMs: Int
        let target: URL
        let temporary: URL
        private let lock = NSLock()
        private var finished = false

        init(transcript: AlignedInterjectionTranscript, durationMs: Int, target: URL, temporary: URL) {
            self.transcript = transcript
            self.durationMs = durationMs
            self.target = target
            self.temporary = temporary
        }

        /// Replaces the original with the cut copy, in one rename. Once only; false if it didn't happen.
        @discardableResult
        public func commit() -> Bool {
            guard claim() else { return false }
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                return true
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
        }

        /// Throws the copy away (the words could not be saved, or nobody will commit). Safe after a commit.
        public func discard() {
            guard claim() else { return }
            try? FileManager.default.removeItem(at: temporary)
        }

        private func claim() -> Bool {
            lock.withLock {
                if finished { return false }
                finished = true
                return true
            }
        }
    }

    /// How far the cut file's length may differ from the cut point before it is not trusted.
    static let durationToleranceMs = 300

    /// The words without the phrase and where to cut, or nil to keep all. Pure; the audio is cut by `prepare`.
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

    /// Cuts a copy of `fileURL` before the phrase. Nil means keep everything: no phrase, a transcript that
    /// disagrees, or any failure. The original is never touched here.
    public static func prepare(fileURL: URL, transcript: AlignedInterjectionTranscript) async -> Prepared? {
        #if canImport(AVFoundation)
        guard let cutPlan = plan(for: transcript) else { return nil }
        // Beside the original, so replacing it is one rename on the same volume.
        let temporary = fileURL.deletingLastPathComponent().appending(path: ".trim-\(UUID().uuidString).m4a")
        do {
            let asset = AVURLAsset(url: fileURL)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                return nil
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
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            return Prepared(transcript: cutPlan.kept, durationMs: trimmedMs, target: fileURL, temporary: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        #else
        return nil
        #endif
    }
}
