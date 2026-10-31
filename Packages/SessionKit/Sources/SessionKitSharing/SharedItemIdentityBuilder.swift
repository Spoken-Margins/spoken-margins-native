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
    /// `textDigests` stand in for hashing `item.text` when the caller has them already (#2506); an item read without
    /// its text needs them.
    public static func localIdentity(
        for item: Item,
        localAudioDigest: String? = nil,
        textDigests: ItemTextDigests? = nil
    ) -> SharedItemIdentity {
        if let linked = linkedFileIdentity(for: item, localAudioDigest: localAudioDigest) { return linked }
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
            normalizedContentSHA256: isPodcast ? nil
                : (textDigests?.normalizedContentSHA256 ?? PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? "")),
            exactEditionSHA256: localAudioDigest ?? (isPodcast ? nil
                : (textDigests?.exactEditionSHA256 ?? PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? "")))
        )
    }

    /// Whether the item is matched by the digests of its text, so a caller reading items without their text knows
    /// whose digests to ask for. An episode of a podcast is matched by its address and GUID instead.
    public static func isMatchedByItsText(_ item: Item) -> Bool {
        !isPodcast(item)
    }

    /// An imported audio file the listener linked to a podcast episode (#755). It stays an audio file
    /// (`.other`, matched by its checksum like any other), and also carries the episode's identity so a
    /// packet shared by link finds it, while the file is still there to be heard. Like a streamed
    /// episode's local identity it is only compared, never sent, and the GUID goes through
    /// `ShareableLinkPolicy` so a GUID that is itself a private link never takes part.
    private static func linkedFileIdentity(for item: Item, localAudioDigest: String?) -> SharedItemIdentity? {
        // Without a valid owned file there is nothing to place Margins on, so the link claims nothing.
        guard item.mediaType == "audiobook", let episode = item.linkedEpisode, localAudioDigest != nil else { return nil }
        let page = episode.pageURL.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        let enclosure = episode.enclosureURL.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        return SharedItemIdentity(
            itemType: .other,
            canonicalURL: page ?? enclosure,
            originalURL: page,
            title: item.title,
            showTitle: bounded(episode.showTitle, 500),
            episodeGUID: bounded(ShareableLinkPolicy.shareableEpisodeGUID(episode.guid), 1_000),
            enclosureURL: enclosure,
            publishedAt: bounded(episode.publishedAt, 100),
            durationMs: item.media?.durationMs,
            exactEditionSHA256: localAudioDigest
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

    /// Reads only fields a Library summary also has, so a caller that holds a summary need not decode the text (#2506).
    public static func itemType<Fields: LibraryItemFields>(for item: Fields) -> SharedItemType {
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

    private static func isPodcast<Fields: LibraryItemFields>(_ item: Fields) -> Bool {
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
