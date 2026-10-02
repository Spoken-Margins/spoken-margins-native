import Foundation
import SessionKit

/// The identity a shared packet carries for an item, and the identity a recipient's own item is
/// matched against. Both sides fill the podcast episode's GUID, show title and publish date (#177),
/// so two subscribers of the same feed match by GUID even when each audio link carries its own
/// token. The GUID goes through `ShareableLinkPolicy`, so a GUID that is itself a private link is
/// never sent or matched on.
public enum SharedItemIdentityBuilder {
    /// The recipient side: what `ImportedItemResolver.canRepresentSameWork` compares a packet against.
    /// `localAudioDigest` is the checksum of a valid local audiobook file, when there is one.
    public static func localIdentity(for item: Item, localAudioDigest: String? = nil) -> SharedItemIdentity {
        let isPodcast = isPodcast(item)
        let external = item.externalReference.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        let enclosure = item.media?.url.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        return SharedItemIdentity(
            itemType: itemType(for: item),
            canonicalURL: external ?? enclosure,
            originalURL: external,
            title: item.title,
            showTitle: isPodcast ? bounded(item.showTitle, 500) : nil,
            episodeGUID: episodeGUID(for: item),
            enclosureURL: enclosure,
            publishedAt: isPodcast ? bounded(item.publishedAt, 100) : nil,
            durationMs: item.media?.durationMs,
            normalizedContentSHA256: isPodcast ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? ""),
            exactEditionSHA256: localAudioDigest ?? (isPodcast ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? ""))
        )
    }

    /// The sender side, for a packet of `draftEditionDigests` (each Margin's source edition digest).
    /// A shared edition digest is used only when every Margin recorded on the same edition.
    public static func exportIdentity(
        for item: Item,
        draftEditionDigests: [String?],
        localAudioDigest: String? = nil
    ) -> SharedItemIdentity {
        let isPodcast = isPodcast(item)
        let external = item.externalReference.flatMap { normalizedSharingURL($0) }
        let enclosure = item.media?.url.flatMap { URL(string: $0)?.scheme?.lowercased() == "https" ? $0 : nil }
        let digests = draftEditionDigests.compactMap { $0 }
        let sharedDigest = digests.count == draftEditionDigests.count && Set(digests).count == 1 ? digests.first : nil
        let articleExact = isPodcast ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? "")
        return SharedItemIdentity(
            itemType: itemType(for: item),
            canonicalURL: external ?? enclosure,
            originalURL: external,
            title: item.title,
            showTitle: isPodcast ? bounded(item.showTitle, 500) : nil,
            episodeGUID: episodeGUID(for: item),
            enclosureURL: enclosure,
            publishedAt: isPodcast ? bounded(item.publishedAt, 100) : nil,
            durationMs: item.media?.durationMs,
            normalizedContentSHA256: isPodcast ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? ""),
            exactEditionSHA256: sharedDigest
                ?? localIdentity(for: item, localAudioDigest: localAudioDigest).exactEditionSHA256
                ?? articleExact
        )
    }

    public static func itemType(for item: Item) -> SharedItemType {
        if item.mediaType == "audiobook" { return .other }
        if isPodcast(item) { return .podcast }
        let extensionName = URL(fileURLWithPath: item.externalReference ?? "").pathExtension.lowercased()
        if extensionName == "pdf" { return .pdf }
        if extensionName == "epub" { return .epub }
        return .text
    }

    /// The https form packets use: lowercased scheme and host, no fragment or trailing slash.
    public static func normalizedSharingURL(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https" else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        while components.path.hasSuffix("/") && components.path.count > 1 { components.path.removeLast() }
        return components.string
    }

    private static func isPodcast(_ item: Item) -> Bool {
        item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile
    }

    private static func episodeGUID(for item: Item) -> String? {
        guard isPodcast(item), item.mediaType != "audiobook" else { return nil }
        return bounded(ShareableLinkPolicy.shareableEpisodeGUID(item.episodeGUID), 1_000)
    }

    /// Feed metadata is untrusted: a value past the packet's field limit is left out rather than
    /// making the whole export fail validation.
    private static func bounded(_ value: String?, _ maximum: Int) -> String? {
        guard let value, value.count <= maximum else { return nil }
        return value
    }
}
