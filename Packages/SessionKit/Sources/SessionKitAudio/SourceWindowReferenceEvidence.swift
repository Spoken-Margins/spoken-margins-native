import Foundation
import SessionKit

/// Signs the audio a source-window job cut from the episode, so the Margin can be matched in another copy (#871).
///
/// This sat inside the app model's job body, where it made the hot file longer and could not be tested alone.
public enum SourceWindowReferenceEvidence {
    public struct Outcome: Equatable, Sendable {
        /// The before and after signatures to keep. Empty when none could be made.
        public let evidence: [CapturedPodcastAnchorEvidence]
        /// Why none could be made. Nil when the window had no audio to sign, or signing worked.
        public let failure: String?
    }

    /// Signs the temporary audio in `analysis`, then deletes it. Never throws: a failure to make the output folder
    /// or to sign is reported in the outcome, because the transcript is still worth keeping without signatures.
    public static func generate(
        from analysis: SourceAudioWindowTranscription,
        anchorMediaTimeMs: Int,
        outputDirectory: Result<URL, any Error>,
        idPrefix: String
    ) async -> Outcome {
        guard let localAudioURL = analysis.localAudioURL else { return Outcome(evidence: [], failure: nil) }
        defer { try? FileManager.default.removeItem(at: localAudioURL.deletingLastPathComponent()) }
        do {
            let directory = try outputDirectory.get()
            let generated = try await PodcastAnchorEvidenceGenerator.generate(
                sourceURL: localAudioURL,
                anchorMediaTimeMs: max(0, anchorMediaTimeMs - analysis.sourceStartMs),
                outputDirectory: directory,
                idPrefix: idPrefix
            )
            return Outcome(evidence: captured(from: generated, provenance: analysis.provenance), failure: nil)
        } catch {
            return Outcome(evidence: [], failure: error.localizedDescription)
        }
    }

    /// The generator names its two flanks with a `-pre` or `-post` suffix; the role follows from that.
    static func captured(
        from generated: [GeneratedPodcastAnchorEvidence],
        provenance: EpisodeFingerprintProvenance
    ) -> [CapturedPodcastAnchorEvidence] {
        generated.map { evidence in
            CapturedPodcastAnchorEvidence(
                id: evidence.id,
                localPath: evidence.fileURL.path,
                durationMs: evidence.durationMs,
                anchorOffsetMs: evidence.anchorOffsetMs,
                provenance: provenance == .downloadedSourceReference
                    ? .downloadedSourceReference
                    : .sourceWindowReference,
                windowRole: evidence.id.hasSuffix("-pre")
                    ? .sourceWindowBefore
                    : .sourceWindowAfter
            )
        }
    }
}
