import Foundation
import SessionKit

/// A `.spokenmargins` file that carries a skim-ready Listening Map for an article or a PDF and no Margins (#1471).
///
/// Every earlier build refuses it by its existing "unsupported capability" path, not by a crash or a half import:
/// the packet declares `capability` as required, and also carries one empty commentary layer so those readers get
/// as far as the capability check (they count the layer before they look at capabilities). The map travels as an
/// ordinary `listening_map_proposal` artifact whose scenes are placed by a short quotation of their first words,
/// the way Margins are, so the packet holds none of the source text beyond those few words per scene.
public enum ListeningMapPacket {
    public static let capability = "spoken-margins.listening-map-packet.v1"

    /// A map packet can name an article, a PDF or an EPUB. Podcast maps travel with fingerprints instead.
    public static let itemTypes: Set<SharedItemType> = [.text, .pdf, .epub]
    public static let maximumScenes = 200

    /// Quoted words per anchor: seven from the scene, two before them. Together they stay under the ten-word run
    /// the share contract treats as quotation (`PortableListeningMapContract.verbatimRunWords`).
    public static let quotedWords = 7
    public static let contextWords = 2

    public static func isMapPacket(_ manifest: SpokenMarginsPackageManifest) -> Bool {
        manifest.requiredCapabilities.contains(capability)
    }

    /// The map a verified map packet carries, or nil for any other packet.
    public static func proposal(in package: VerifiedSpokenMarginsPackage) -> PortableListeningMapProposalArtifact? {
        isMapPacket(package.manifest) ? package.listeningMapProposals.first : nil
    }
}

/// Finds the Library item a map packet is about.
///
/// The usual identity match comes first (link, then content hash). A PDF or EPUB the listener picked themselves
/// has neither the sender's link nor, necessarily, the sender's extracted text, so those are also tried by where
/// the map's quotations land in each file of the same kind: the item that holds the map's chapters wins, and two
/// that hold them equally well are ambiguous, so the listener is asked rather than guessed for.
public enum ListeningMapPacketItemMatcher {
    public enum Match: Equatable, Sendable {
        case item(String)
        case none
        case ambiguous
    }

    /// A file of the same kind must hold at least this share of the map's chapters to stand for the packet's item.
    public static let minimumPlacedFraction = 0.8

    /// The media types the app saves readable documents under: articles, PDFs and EPUBs. Audio never carries a text map.
    static let readableDocumentTypes: Set<String> = ["text", "pdf", "epub"]

    /// What the item is as a document. The saved media type decides first, because a PDF fetched from a link may have
    /// no `.pdf` ending for `SharedItemIdentityBuilder.itemType(for:)` to read.
    static func documentType(of item: Item) -> SharedItemType {
        switch item.mediaType {
        case "pdf": return .pdf
        case "epub": return .epub
        default: return SharedItemIdentityBuilder.itemType(for: item)
        }
    }

    /// The one document the packet's identity names, judged without reading any item's text when `textDigests` are
    /// given (#2506). `match` begins with this; placing the chapters on a PDF's or EPUB's text comes after it, and is the
    /// only step that needs the text.
    public static func identityMatch(
        packetItem: SharedItemIdentity,
        among items: [Item],
        textDigests: (Item) -> ItemTextDigests? = { _ in nil }
    ) -> String? {
        let candidates = items.filter { $0.deletedAt == nil && readableDocumentTypes.contains($0.mediaType) }
        return SharedPacketItemMatcher.matchingItemId(for: packetItem, among: candidates, textDigests: textDigests)
    }

    public static func match(
        packetItem: SharedItemIdentity,
        proposal: PortableListeningMapProposalArtifact,
        among items: [Item]
    ) -> Match {
        let candidates = items.filter { $0.deletedAt == nil && readableDocumentTypes.contains($0.mediaType) }
        if let identityMatch = identityMatch(packetItem: packetItem, among: candidates) {
            return .item(identityMatch)
        }
        guard packetItem.itemType == .pdf || packetItem.itemType == .epub else { return .none }
        var best: (id: String, fraction: Double)?
        var tied = false
        for item in candidates where documentType(of: item) == packetItem.itemType {
            guard let text = item.text, !text.isEmpty else { continue }
            let placement = TextListeningMapPlacer.place(
                proposal, in: text, expectedExactEditionSHA256: packetItem.exactEditionSHA256,
                minimumPlacedFraction: minimumPlacedFraction, giveUpIfNoneOfFirst: 4
            )
            guard placement.isUsable else { continue }
            let fraction = Double(placement.scenes.count) / Double(max(1, placement.totalSceneCount))
            guard fraction >= minimumPlacedFraction else { continue }
            if let current = best {
                if fraction > current.fraction { best = (item.id, fraction); tied = false }
                else if fraction == current.fraction { tied = true }
            } else {
                best = (item.id, fraction)
            }
        }
        guard let best else { return .none }
        return tied ? .ambiguous : .item(best.id)
    }
}
