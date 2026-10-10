import Foundation
import SessionKit

/// Finds the Library item a shared packet is about, so packets from several senders on the same work land
/// on one item whatever order they arrive in (#468). Moved from Gate1AppModel so it can be host-tested.
public enum SharedPacketItemMatcher {
    /// The one Library item that can stand for the packet's item, or nil when none or several can.
    /// `ownedAudiobookDigest` gives the checksum of a valid owned audiobook file for an item, if any.
    public static func matchingItemId(
        for packetItem: SharedItemIdentity,
        among items: [Item],
        ownedAudiobookDigest: (Item) -> String? = { _ in nil }
    ) -> String? {
        let matches = items.filter { item in
            ImportedItemResolver.canRepresentSameWork(
                packetItem,
                localIdentity(for: item, ownedAudiobookDigest: ownedAudiobookDigest(item))
            )
        }
        if matches.count == 1 { return matches[0].id }
        // The listener linked their own file to this episode, and a streamed copy of it exists too (an earlier
        // link-shared packet added one). The file they chose wins; any other owned file that matches, or a
        // second linked file, is still ambiguous (#755).
        let ownedFiles = matches.filter { $0.mediaType == "audiobook" }
        if ownedFiles.count == 1, ownedFiles[0].linkedEpisode != nil { return ownedFiles[0].id }
        return nil
    }

    /// How a Library item describes itself when it is compared with a packet's item.
    public static func localIdentity(for item: Item, ownedAudiobookDigest: String?) -> SharedItemIdentity {
        SharedItemIdentityBuilder.localIdentity(
            for: item, localAudioDigest: item.mediaType == "audiobook" ? ownedAudiobookDigest : nil
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

    public static func itemType(for item: Item) -> SharedItemType {
        SharedItemIdentityBuilder.itemType(for: item)
    }
}
