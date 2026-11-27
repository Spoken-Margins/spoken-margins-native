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

    /// What the sentence beside the link needs to know (#5264), from the same verified packet as the preview: the
    /// item's type, the Margins going (how many, and whether each is the sender's own voice), and whether the packet
    /// carries an audio address or the preview a public page.
    public static func facts(of package: VerifiedSpokenMarginsPackage, preview: ShareLinkPreview) -> ShareLinkMessage.Facts {
        let item = package.manifest.item
        let kinds = package.commentaryLayers
            .flatMap(\.interjections)
            .map { $0.defaultRepresentation?.kind }
        return ShareLinkMessage.Facts(
            itemType: item.itemType,
            notes: ShareLinkMessage.Notes(kinds: kinds),
            hasAudioOrPage: item.enclosureURL != nil || preview.source.url != nil
        )
    }

    /// Reads the packet file once and builds its preview and the sentence's facts. The audio is extracted into
    /// `scratch` and left for the caller to delete.
    public static func read(ofPackageAt url: URL, scratch: URL) throws -> (preview: ShareLinkPreview, facts: ShareLinkMessage.Facts) {
        let package = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: scratch)
        let preview = try preview(of: package)
        return (preview, facts(of: package, preview: preview))
    }

    /// Reads the packet file and builds its preview. The audio is extracted into `scratch` and left for the caller
    /// to delete.
    public static func preview(ofPackageAt url: URL, scratch: URL) throws -> ShareLinkPreview {
        try read(ofPackageAt: url, scratch: scratch).preview
    }
}
