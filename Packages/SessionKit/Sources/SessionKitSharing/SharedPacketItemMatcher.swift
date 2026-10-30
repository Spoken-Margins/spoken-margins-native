import Foundation
import SessionKit

/// Finds the Library item a shared packet is about, so packets from several senders on the same work land
/// on one item whatever order they arrive in (#468). Moved from Gate1AppModel so it can be host-tested.
public enum SharedPacketItemMatcher {
    /// The one Library item that can stand for the packet's item, or nil when none or several can.
    /// `ownedAudiobookDigest` gives the checksum of a valid owned audiobook file for an item, if any.
    ///
    /// A listener can hold one work as several editions (a re-added article whose text changed keeps the old
    /// copy), so several items can qualify. Stronger evidence wins first: the exact edition the packet names,
    /// then the same normalized text. Only an article, PDF or EPUB packet that still ties after that lands on
    /// the most recently added copy rather than on nothing, since "nothing" makes import fetch a third copy (#1257).
    public static func matchingItemId(
        for packetItem: SharedItemIdentity,
        among items: [Item],
        ownedAudiobookDigest: (Item) -> String? = { _ in nil },
        textDigests: (Item) -> ItemTextDigests? = { _ in nil }
    ) -> String? {
        let candidates = items.map { item in
            (item: item, identity: localIdentity(
                for: item, ownedAudiobookDigest: ownedAudiobookDigest(item), textDigests: textDigests(item)))
        }.filter { ImportedItemResolver.canRepresentSameWork(packetItem, $0.identity) }
        if candidates.count == 1 { return candidates[0].item.id }
        // The listener linked their own file to this episode, and a streamed copy of it exists too (an earlier
        // link-shared packet added one). The file they chose wins; any other owned file that matches, or a
        // second linked file, is still ambiguous (#755).
        let ownedFiles = candidates.filter { $0.item.mediaType == "audiobook" }
        if ownedFiles.count == 1, ownedFiles[0].item.linkedEpisode != nil { return ownedFiles[0].item.id }
        guard candidates.count > 1, [.text, .pdf, .epub].contains(packetItem.itemType) else { return nil }
        let exact = candidates.filter { sameDigest(packetItem.exactEditionSHA256, $0.identity.exactEditionSHA256) }
        let sameText = candidates.filter { sameDigest(packetItem.normalizedContentSHA256, $0.identity.normalizedContentSHA256) }
        // Address alone is the weakest evidence, so it only chooses among readable copies: an audio episode on
        // the same page is not a copy of the article.
        let sameKind = candidates.filter { [.text, .pdf, .epub].contains($0.identity.itemType) }
        let tier = !exact.isEmpty ? exact : (!sameText.isEmpty ? sameText : sameKind)
        if tier.isEmpty { return nil }
        if tier.count == 1 { return tier[0].item.id }
        return tier.max { newer($1.item, than: $0.item) }?.item.id
    }

    private static func sameDigest(_ packet: String?, _ local: String?) -> Bool {
        guard let packet, let local else { return false }
        return packet == local
    }

    /// Later `createdAt` wins; an item with no date is oldest, and the id breaks an exact tie the same way each time.
    private static func newer(_ lhs: Item, than rhs: Item) -> Bool {
        let (l, r) = (lhs.createdAt ?? .distantPast, rhs.createdAt ?? .distantPast)
        return l != r ? l > r : lhs.id > rhs.id
    }

    /// How a Library item describes itself when it is compared with a packet's item.
    public static func localIdentity(
        for item: Item,
        ownedAudiobookDigest: String?,
        textDigests: ItemTextDigests? = nil
    ) -> SharedItemIdentity {
        SharedItemIdentityBuilder.localIdentity(
            for: item, localAudioDigest: item.mediaType == "audiobook" ? ownedAudiobookDigest : nil, textDigests: textDigests
        )
    }

    public static func layerHasValidItemAssociation(
        _ layer: ImportedCommentaryLayer,
        item: Item?,
        ownedAudiobookDigest: String?
    ) -> Bool {
        guard layer.sourceResolutionStatus != .wrongSource,
              layer.itemId != nil,
              let item else { return false }
        guard item.deletedAt == nil else { return false }
        return ImportedItemResolver.canRepresentSameWork(
            layer.itemIdentity,
            localIdentity(for: item, ownedAudiobookDigest: ownedAudiobookDigest)
        )
    }

    /// The layers that sit on a linked file only because of its episode link (#755): ones the file would no longer
    /// represent once the link is gone. A layer from a packet that names the exact file by checksum does not
    /// depend on the link, so it never stops the listener from fixing a wrong one.
    public static func layersDependingOnEpisodeLink(
        _ layers: [ImportedCommentaryLayer],
        item: Item,
        ownedAudiobookDigest: String?
    ) -> [ImportedCommentaryLayer] {
        guard item.linkedEpisode != nil else { return [] }
        let withoutLink = localIdentity(
            for: ImportedFileEpisodeLink.unlink(item), ownedAudiobookDigest: ownedAudiobookDigest
        )
        return layers.filter { $0.deletedAt == nil && !ImportedItemResolver.canRepresentSameWork($0.itemIdentity, withoutLink) }
    }

    public static func ownedAudiobookDigest(for item: Item, assets: [OwnedOfflineAsset]) -> String? {
        guard item.mediaType == "audiobook" else { return nil }
        return assets.first(where: {
            $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid
        })?.checksumSHA256
    }

    public static func itemType<Fields: LibraryItemFields>(for item: Fields) -> SharedItemType {
        SharedItemIdentityBuilder.itemType(for: item)
    }
}
