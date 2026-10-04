import Foundation
import SessionKit

/// Whether a packet may land on the listener's own audio file, and how its positions are trusted (#468).
///
/// A packet that names this exact file (`ExactLocalAudioImport`) places Margins and maps at the sender's
/// times. A podcast packet matched to the listener's copy of the episode, by its digest or a retained link,
/// is placed the way a downloaded episode is: acoustic and transcript evidence, never the sender's times.
public enum LocalAudioPacketAdmission: Equatable, Sendable {
    case exactEdition
    case podcastCommentary

    /// `actualDigest` is the SHA-256 of the file's bytes now; nil means the packet is refused.
    public static func admission(
        source: SharedItemIdentity,
        recipient: SharedItemIdentity,
        actualDigest: String
    ) -> LocalAudioPacketAdmission? {
        // The file must still be the one the Library recorded, whatever the packet is.
        guard actualDigest == recipient.exactEditionSHA256 else { return nil }
        if ExactLocalAudioImport.matches(source, recipient) { return .exactEdition }
        return source.itemType == .podcast ? .podcastCommentary : nil
    }

    /// The admission for a packet about to import onto owned audio, or the error that refuses it. An exact
    /// edition's maps must project onto the file before anything is imported.
    public static func admitted(
        _ contents: VerifiedSpokenMarginsPackage,
        recipient: SharedItemIdentity,
        itemId: String,
        actualDigest: String
    ) throws -> LocalAudioPacketAdmission {
        guard let admission = admission(source: contents.manifest.item, recipient: recipient, actualDigest: actualDigest) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("The audio bytes do not match this listening package")
        }
        for proposal in contents.listeningMapProposals where admission == .exactEdition {
            _ = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: itemId
            )
        }
        return admission
    }
}
