import Foundation
import SessionKit

/// Everything a Margin packet needs from the database about the item it is built for, read in one go (#2506).
///
/// The share export used to make six separate store reads on the main actor between building each Margin's
/// revision: the item, its map proposals and current projection, the fingerprint spine, the phrase sketch and the
/// whole stored transcript (several MB for a mapped podcast, only to join its words). `SQLiteSessionStore
/// .sharedPacketSource(itemId:includesFingerprintSpine:)` does all of them, so the app runs it through
/// `StoreReader` and the main actor only waits.
public struct SharedPacketSource: Sendable, Equatable {
    public let item: Item
    public let mapProposals: [PortableListeningMapProposalArtifact]
    /// The id of the proposal the item's current projection was resolved from, if it has a projection.
    public let currentMapProposalId: String?
    /// The item's fingerprint spine, only when the sender chose to include acoustic evidence.
    public let fingerprintSpine: EditionFingerprintSpineArtifact?
    public let phraseSketch: TranscriptPhraseSketchArtifact?
    /// The stored transcript's segments joined by single spaces, or nil when the item has no stored transcript.
    public let transcriptText: String?

    /// The item's own text and the transcript's, for the packet's "does this look like the same source" check.
    public var localSourceTexts: [String] {
        [item.text, transcriptText].compactMap { $0 }
    }
}

extension SQLiteSessionStore {
    public func sharedPacketSource(itemId: String, includesFingerprintSpine: Bool) throws -> SharedPacketSource {
        SharedPacketSource(
            item: try loadItem(id: itemId),
            mapProposals: try loadPortableListeningMapProposals(itemId: itemId),
            currentMapProposalId: try loadResolvedListeningMapProjection(itemId: itemId)?.proposalId,
            fingerprintSpine: includesFingerprintSpine ? try loadEditionFingerprintSpine(itemId: itemId) : nil,
            phraseSketch: try loadTranscriptPhraseSketch(itemId: itemId),
            transcriptText: try loadTranscriptTimeline(itemId: itemId)?.timeline.segments.map(\.text).joined(separator: " ")
        )
    }
}
