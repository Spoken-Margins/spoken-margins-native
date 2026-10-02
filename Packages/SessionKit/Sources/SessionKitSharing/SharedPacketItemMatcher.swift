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
        return matches.count == 1 ? matches[0].id : nil
    }

    /// How a Library item describes itself when it is compared with a packet's item.
    public static func localIdentity(for item: Item, ownedAudiobookDigest: String?) -> SharedItemIdentity {
        SharedItemIdentityBuilder.localIdentity(
            for: item, localAudioDigest: item.mediaType == "audiobook" ? ownedAudiobookDigest : nil
        )
    }

    public static func itemType(for item: Item) -> SharedItemType {
        SharedItemIdentityBuilder.itemType(for: item)
    }
}
