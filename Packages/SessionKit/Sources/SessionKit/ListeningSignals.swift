import Foundation

/// I4, the on-device engagement log that D3 ranks followed sources from (#483, #176).
///
/// One JSON object per line. Rows carry opaque ids, display titles, kinds, times and counts only:
/// never Margin text, transcripts, audio, packet payloads or feed URLs (a private feed URL is a
/// credential). The published schema is `Contracts/schemas/i4-engagement.schema.json`.
public enum ListeningSignalFormat {
    public static let schemaVersion = "i4-engagement.1"
}

public struct ListeningSignalSource: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// I2 subscription kind: `podcast_feed`, `article_feed`, `website` or `bridged_site`.
    public var subscriptionKind: String
    /// I2 content kind: `podcast`, `article`, `newsletter`, `paper`, `news`, `video`, or a future value.
    public var contentKind: String
    public var categories: [String]

    public init(id: String, title: String, subscriptionKind: String, contentKind: String, categories: [String] = []) {
        self.id = id
        self.title = title
        self.subscriptionKind = subscriptionKind
        self.contentKind = contentKind
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey {
        case id, title, categories
        case subscriptionKind = "subscription_kind"
        case contentKind = "content_kind"
    }
}

public struct ListeningSignalItem: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var publishedAt: Date
    public var durationSeconds: Double?

    public init(id: String, title: String, publishedAt: Date, durationSeconds: Double? = nil) {
        self.id = id
        self.title = title
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case publishedAt = "published_at"
        case durationSeconds = "duration_seconds"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(publishedAt, forKey: .publishedAt)
        if let durationSeconds {
            try container.encode(durationSeconds, forKey: .durationSeconds)
        } else {
            try container.encodeNil(forKey: .durationSeconds)
        }
    }
}

public enum ListeningSignalMarginKind: String, Codable, Equatable, Sendable {
    case spoken
    case written
}

public enum ListeningSignalEvent: Equatable, Sendable {
    /// A followed source published an item (first seen on refresh).
    case itemPublished
    /// One coalesced listening interval, in wall-clock seconds while playback was active.
    case listened(seconds: Double)
    /// A Margin was saved. Length is seconds for spoken Margins and characters for written ones.
    case margin(kind: ListeningSignalMarginKind, length: Int)
    /// A packet for the item went out through the system share sheet.
    case share
    /// A `.spokenmargins` packet was built for the item.
    case export(packetId: String?, marginCount: Int)
    /// A packet was imported. `fromOther` is false when this device exported the same packet.
    case packetImport(packetId: String, fromOther: Bool, marginCount: Int)
    /// An item was dismissed from Following.
    case dismiss
    /// An item was marked or observed finished.
    case finish

    public var name: String {
        switch self {
        case .itemPublished: "item_published"
        case .listened: "listened"
        case .margin: "margin"
        case .share: "share"
        case .export: "export"
        case .packetImport: "packet_import"
        case .dismiss: "dismiss"
        case .finish: "finish"
        }
    }
}

public struct ListeningSignal: Codable, Equatable, Sendable {
    public var event: ListeningSignalEvent
    public var at: Date
    public var source: ListeningSignalSource
    public var item: ListeningSignalItem?

    public init(event: ListeningSignalEvent, at: Date, source: ListeningSignalSource, item: ListeningSignalItem?) {
        self.event = event
        self.at = at
        self.source = source
        self.item = item
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event, at, source, item, seconds, length
        case marginKind = "margin_kind"
        case lengthUnit = "length_unit"
        case marginCount = "margin_count"
        case packetId = "packet_id"
        case fromOther = "from_other"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ListeningSignalFormat.schemaVersion, forKey: .schemaVersion)
        try container.encode(event.name, forKey: .event)
        try container.encode(at, forKey: .at)
        try container.encode(source, forKey: .source)
        if let item {
            try container.encode(item, forKey: .item)
        } else {
            try container.encodeNil(forKey: .item)
        }
        switch event {
        case .itemPublished, .share, .dismiss, .finish:
            break
        case .listened(let seconds):
            try container.encode(seconds, forKey: .seconds)
        case .margin(let kind, let length):
            try container.encode(kind, forKey: .marginKind)
            try container.encode(length, forKey: .length)
            try container.encode(kind == .spoken ? "seconds" : "characters", forKey: .lengthUnit)
        case .export(let packetId, let marginCount):
            try container.encodeIfPresent(packetId, forKey: .packetId)
            try container.encode(marginCount, forKey: .marginCount)
        case .packetImport(let packetId, let fromOther, let marginCount):
            try container.encode(packetId, forKey: .packetId)
            try container.encode(fromOther, forKey: .fromOther)
            try container.encode(marginCount, forKey: .marginCount)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .schemaVersion)
        guard version == ListeningSignalFormat.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "unsupported \(version)")
        }
        at = try container.decode(Date.self, forKey: .at)
        source = try container.decode(ListeningSignalSource.self, forKey: .source)
        item = try container.decodeIfPresent(ListeningSignalItem.self, forKey: .item)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case "item_published": event = .itemPublished
        case "listened": event = .listened(seconds: try container.decode(Double.self, forKey: .seconds))
        case "margin":
            event = .margin(
                kind: try container.decode(ListeningSignalMarginKind.self, forKey: .marginKind),
                length: try container.decode(Int.self, forKey: .length)
            )
        case "share": event = .share
        case "export":
            event = .export(
                packetId: try container.decodeIfPresent(String.self, forKey: .packetId),
                marginCount: try container.decode(Int.self, forKey: .marginCount)
            )
        case "packet_import":
            event = .packetImport(
                packetId: try container.decode(String.self, forKey: .packetId),
                fromOther: try container.decode(Bool.self, forKey: .fromOther),
                marginCount: try container.decode(Int.self, forKey: .marginCount)
            )
        case "dismiss": event = .dismiss
        case "finish": event = .finish
        default:
            throw DecodingError.dataCorruptedError(forKey: .event, in: container, debugDescription: "unknown event \(name)")
        }
    }
}

/// Maps the app's followed sources and Library items to I4 rows. Only items from a followed
/// source are logged: I4 ranks followed sources, and an item without one has no source id to
/// group under.
public enum ListeningSignalContext {
    public typealias Value = (source: ListeningSignalSource, item: ListeningSignalItem)

    public static func load(forItemId itemId: String, from repository: any SessionRepository,
                            redirects: [String: String] = [:]) -> Value? {
        guard let item = try? repository.loadItem(id: itemId),
              let subscriptions = try? repository.loadFeedSubscriptions(), !subscriptions.isEmpty else { return nil }
        return context(for: item, subscriptions: subscriptions,
                       entries: (try? repository.loadFeedEntries(subscriptionId: nil)) ?? [], redirects: redirects)
    }
    public static func source(for subscription: FeedSubscription) -> ListeningSignalSource {
        ListeningSignalSource(
            id: subscription.source.id,
            title: nonEmpty(subscription.source.title) ?? nonEmpty(subscription.source.host) ?? untitled,
            subscriptionKind: subscription.source.kind.rawValue,
            contentKind: contentKind(for: subscription.source.kind)
        )
    }

    /// An entry without a publication date is dated when it was first seen. Feed entries don't
    /// store a duration, so the refresh that parsed it passes the feed's own when it has one.
    public static func item(for entry: FeedEntry, seenAt: Date, durationMs: Int? = nil) -> ListeningSignalItem {
        ListeningSignalItem(
            id: entry.id,
            title: nonEmpty(entry.title) ?? untitled,
            publishedAt: entry.publishedAt ?? seenAt,
            durationSeconds: durationMs.map { Double($0) / 1_000 }
        )
    }

    public static func context(
        forEntryId entryId: String,
        entries: [FeedEntry],
        subscriptions: [FeedSubscription],
        seenAt: Date
    ) -> (source: ListeningSignalSource, item: ListeningSignalItem)? {
        guard let entry = entries.first(where: { $0.id == entryId }),
              let subscription = subscriptions.first(where: { $0.id == entry.subscriptionId }) else { return nil }
        return (source(for: subscription), item(for: entry, seenAt: seenAt))
    }

    /// The followed source a Library item came from, and the feed entry it was imported from when
    /// one matches, so its item id joins the `item_published` row. Unmatched items keep a
    /// Library-scoped id; their source-level signals still count. `redirects` maps an article's
    /// final URL to the feed entry link that led there (`ListeningSignalRedirects`).
    public static func context(
        for item: Item,
        subscriptions: [FeedSubscription],
        entries: [FeedEntry],
        redirects: [String: String] = [:]
    ) -> (source: ListeningSignalSource, item: ListeningSignalItem)? {
        let knownSubscription = followedSubscription(for: item, subscriptions: subscriptions)
        let entry = importedEntry(for: item, among: entries.filter { entry in
            subscriptions.contains(where: { $0.id == entry.subscriptionId })
        }, knownSubscriptionId: knownSubscription?.id, redirects: redirects)
        guard let subscription = entry.flatMap({ entry in subscriptions.first { $0.id == entry.subscriptionId } })
                ?? knownSubscription else { return nil }
        let duration = item.media?.durationMs.map { Double($0) / 1_000 }
        let signalItem = ListeningSignalItem(
            id: entry?.id ?? "library-\(item.id)",
            title: nonEmpty(entry?.title) ?? nonEmpty(item.title) ?? untitled,
            publishedAt: entry?.publishedAt ?? item.createdAt ?? Date(timeIntervalSince1970: 0),
            durationSeconds: duration
        )
        return (source(for: subscription), signalItem)
    }

    /// The feed entry an item was imported from. An episode GUID or audio URL names one episode;
    /// a webpage several episodes share decides only when one entry has it, so signals are never
    /// filed under whichever of them the feed listed first. A GUID is only unique within one feed,
    /// so it counts only inside the item's own followed source; another feed needs a URL match.
    static func importedEntry(for item: Item, among entries: [FeedEntry], knownSubscriptionId: String?,
                              redirects: [String: String] = [:]) -> FeedEntry? {
        let urls = Set([item.externalReference, item.media?.url].compactMap(FollowedSourceMatching.normalizedFollowSourceURL))
        let itemKeys = urls.union(urls.compactMap { redirects[$0] })
        let guid = nonEmpty(item.episodeGUID)
        let matchesGUID: (FeedEntry) -> Bool = {
            guid != nil && $0.subscriptionId == knownSubscriptionId && nonEmpty($0.episodeGUID) == guid
        }
        let matchesAudio: (FeedEntry) -> Bool = {
            FollowedSourceMatching.normalizedFollowSourceURL($0.audioURL).map(itemKeys.contains) ?? false
        }
        let matchesPage: (FeedEntry) -> Bool = {
            FollowedSourceMatching.normalizedFollowSourceURL($0.canonicalURL).map(itemKeys.contains) ?? false
        }
        var candidates = entries.filter { matchesGUID($0) || matchesAudio($0) || matchesPage($0) }
        for narrower in [matchesGUID, matchesAudio, matchesPage] where candidates.count > 1 {
            let narrowed = candidates.filter(narrower)
            if !narrowed.isEmpty { candidates = narrowed }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func followedSubscription(for item: Item, subscriptions: [FeedSubscription]) -> FeedSubscription? {
        if let sourceURL = FollowedSourceMatching.normalizedFollowSourceURL(item.sourceURL) {
            return subscriptions.first(where: {
               FollowedSourceMatching.normalizedFollowSourceURL($0.source.canonicalURL) == sourceURL
            })
        }
        guard let title = nonEmpty(item.sourceTitle) else { return nil }
        return subscriptions.first {
            (nonEmpty($0.source.title) ?? $0.source.host).caseInsensitiveCompare(title) == .orderedSame
        }
    }

    static func contentKind(for kind: SourceIdentityKind) -> String {
        switch kind {
        case .podcastFeed: SourceContentKind.podcast.rawValue
        case .articleFeed, .website: SourceContentKind.article.rawValue
        }
    }

    /// Titles are for reading the log; D3's evaluator rejects an empty one.
    static let untitled = "Untitled"

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
