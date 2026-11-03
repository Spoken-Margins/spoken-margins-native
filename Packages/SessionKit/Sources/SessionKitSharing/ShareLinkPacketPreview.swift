import Foundation
import SessionKit

/// The preview a share link carries, made from the packet the sender is about to share (#487). Reading the verified
/// packet, not the draft on screen, keeps the link's page in step with what the friend's phone will import.
public enum ShareLinkPacketPreview {
    /// Words only: each Margin's approved transcript in the order they were made, the item's title and show, and the
    /// item's public web page when it has one. The packet's audio and any source text stay out.
    public static func preview(of package: VerifiedSpokenMarginsPackage) throws -> ShareLinkPreview {
        let item = package.manifest.item
        let texts = package.commentaryLayers
            .flatMap(\.interjections)
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.defaultRepresentation?.approvedTranscript ?? "" }
        return try ShareLinkPreviewBuilder.make(
            title: item.title,
            show: item.showTitle,
            pageURL: item.canonicalURL,
            enclosureURL: item.enclosureURL,
            marginTexts: texts
        )
    }

    /// Reads the packet file and builds its preview. The audio is extracted into `scratch` and left for the caller
    /// to delete.
    public static func preview(ofPackageAt url: URL, scratch: URL) throws -> ShareLinkPreview {
        try preview(of: SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: scratch))
    }
}
