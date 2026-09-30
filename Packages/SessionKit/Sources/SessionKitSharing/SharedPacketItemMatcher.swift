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
        let isPodcast = item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile
        let external = item.externalReference.flatMap { normalizedHTTPSURL($0) == nil ? nil : $0 }
        let enclosure = item.media?.url.flatMap { normalizedHTTPSURL($0) == nil ? nil : $0 }
        let localAudioDigest = item.mediaType == "audiobook" ? ownedAudiobookDigest : nil
        return SharedItemIdentity(
            itemType: itemType(for: item),
            canonicalURL: external ?? enclosure,
            originalURL: external,
            title: item.title,
            enclosureURL: enclosure,
            durationMs: item.media?.durationMs,
            normalizedContentSHA256: isPodcast ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? ""),
            exactEditionSHA256: localAudioDigest ?? (isPodcast ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? ""))
        )
    }

    public static func itemType(for item: Item) -> SharedItemType {
        if item.mediaType == "audiobook" { return .other }
        if item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile {
            return .podcast
        }
        let extensionName = URL(fileURLWithPath: item.externalReference ?? "").pathExtension.lowercased()
        if extensionName == "pdf" { return .pdf }
        if extensionName == "epub" { return .epub }
        return .text
    }

    private static func normalizedHTTPSURL(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https" else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        while components.path.hasSuffix("/") && components.path.count > 1 { components.path.removeLast() }
        return components.string
    }
}
