import Foundation

// Seam I2: sources a listener hasn't followed yet (the first-run drawer, later
// suggestions). Schema: Contracts/schemas/source-catalog.schema.json.
// Kinds are open string values so a newer remote catalog never breaks decoding;
// readers skip what they can't follow.

/// How a source is followed. Matches `SourceIdentityKind` where one exists.
public struct SourceKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let podcastFeed = SourceKind(rawValue: "podcast_feed")
    public static let articleFeed = SourceKind(rawValue: "article_feed")
    public static let website = SourceKind(rawValue: "website")
    /// A site without RSS, followed through the B4 bridge (seam I3).
    public static let bridgedSite = SourceKind(rawValue: "bridged_site")

    /// The kind the existing follow path stores, or nil when this build can't follow it.
    public var identityKind: SourceIdentityKind? { SourceIdentityKind(rawValue: rawValue) }
}

/// What a source is, for filtering (D3).
public struct SourceContentKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let podcast = SourceContentKind(rawValue: "podcast")
    public static let article = SourceContentKind(rawValue: "article")
    public static let newsletter = SourceContentKind(rawValue: "newsletter")
    public static let paper = SourceContentKind(rawValue: "paper")
    public static let news = SourceContentKind(rawValue: "news")
    public static let video = SourceContentKind(rawValue: "video")
}

public struct SourceCatalogProvenance: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// apple_top_chart, itunes_lookup, podcast_index, hand_curated, or a newer value.
    public var kind: String
    public var url: String?
    public var country: String?
    public var appleGenreId: Int?
    public var chartUpdatedAt: String?
    public var fetchedAt: String
    public var note: String?
}

public struct SourceCatalogSubject: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var appleGenreId: Int?

    public init(id: String, title: String, appleGenreId: Int? = nil) {
        self.id = id
        self.title = title
        self.appleGenreId = appleGenreId
    }
}

public struct SourceCatalogStarterRow: Codable, Equatable, Sendable {
    public var subjectId: String
    public var title: String
    public var entryIds: [String]
    /// "owner" once the owner has edited the row; "chart-seed" before that.
    public var curatedBy: String?
}

public struct SourceCatalogChartPosition: Codable, Equatable, Hashable, Sendable {
    public var provenanceId: String
    public var rank: Int
}

public struct SourceExternalIds: Codable, Equatable, Hashable, Sendable {
    public var applePodcastsId: String?
    public var podcastIndexId: String?
    public var podcastGuid: String?
    public var youtubeChannelId: String?
    public var spotifyShowId: String?

    public init(applePodcastsId: String? = nil, podcastIndexId: String? = nil, podcastGuid: String? = nil, youtubeChannelId: String? = nil, spotifyShowId: String? = nil) {
        self.applePodcastsId = applePodcastsId
        self.podcastIndexId = podcastIndexId
        self.podcastGuid = podcastGuid
        self.youtubeChannelId = youtubeChannelId
        self.spotifyShowId = spotifyShowId
    }
}

public struct SourceCatalogEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceKind
    public var contentKind: SourceContentKind
    public var title: String
    public var author: String?
    /// Always an https feed from a public directory. Catalogs never carry private feeds (#168).
    public var feedURL: String
    public var artworkURL: String?
    public var websiteURL: String?
    public var summary: String?
    /// The first subject is the primary one.
    public var subjects: [String]
    public var explicit: Bool?
    public var chartPositions: [SourceCatalogChartPosition]?
    public var externalIds: SourceExternalIds?
    public var provenanceIds: [String]

    public init(id: String, kind: SourceKind, contentKind: SourceContentKind, title: String, author: String? = nil, feedURL: String, artworkURL: String? = nil, websiteURL: String? = nil, summary: String? = nil, subjects: [String], explicit: Bool? = nil, chartPositions: [SourceCatalogChartPosition]? = nil, externalIds: SourceExternalIds? = nil, provenanceIds: [String]) {
        self.id = id
        self.kind = kind
        self.contentKind = contentKind
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.websiteURL = websiteURL
        self.summary = summary
        self.subjects = subjects
        self.explicit = explicit
        self.chartPositions = chartPositions
        self.externalIds = externalIds
        self.provenanceIds = provenanceIds
    }

    public var primarySubject: String? { subjects.first }

    /// Best chart rank across every chart the entry appears in, for ordering.
    public var bestRank: Int { chartPositions?.map(\.rank).min() ?? Int.max }

    /// True when this build's follow path can follow the entry.
    public var isFollowable: Bool { kind.identityKind == .podcastFeed || kind.identityKind == .articleFeed }

    /// True when the first-run drawer offers the entry: followable and not marked explicit (#544,
    /// owner 2026-09-30, to keep the App Store age rating low). A show with no flag stays in.
    /// Listeners can still follow any feed themselves, and Following still finds its catalog tags.
    public var isOfferedAsStarter: Bool { isFollowable && explicit != true }
}

public struct SourceCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "source-catalog.v1"

    public var schemaVersion: String
    public var catalogId: String
    public var contentVersion: Int
    public var title: String
    public var generatedAt: String
    public var locale: String?
    public var provenance: [SourceCatalogProvenance]
    public var subjects: [SourceCatalogSubject]
    public var starterRows: [SourceCatalogStarterRow]?
    public var entries: [SourceCatalogEntry]

    /// Subjects that have at least one entry the drawer offers, in catalog order.
    public var visibleSubjects: [SourceCatalogSubject] {
        let used = Set(entries.filter(\.isOfferedAsStarter).flatMap(\.subjects))
        return subjects.filter { used.contains($0.id) }
    }

    /// Entries for one subject chip (nil = all): the subject's starter row first,
    /// in the owner's order, then the rest by best chart rank. Only entries the drawer offers:
    /// followable and not marked explicit.
    public func entries(forSubject subjectId: String?) -> [SourceCatalogEntry] {
        let followable = entries.filter(\.isOfferedAsStarter)
        guard let subjectId else {
            return followable.enumerated().sorted { lhs, rhs in
                (lhs.element.bestRank, lhs.offset) < (rhs.element.bestRank, rhs.offset)
            }.map(\.element)
        }
        let byId = Dictionary(followable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let starterIds = starterRows?.first { $0.subjectId == subjectId }?.entryIds ?? []
        let starters = starterIds.compactMap { byId[$0] }.filter { $0.subjects.contains(subjectId) }
        let starterSet = Set(starters.map(\.id))
        let rest = followable.enumerated()
            .filter { $0.element.subjects.contains(subjectId) && !starterSet.contains($0.element.id) }
            .sorted { lhs, rhs in
                // Shows whose primary subject this is come before those that only list it.
                let lhsKey = (lhs.element.primarySubject == subjectId ? 0 : 1, lhs.element.bestRank, lhs.offset)
                let rhsKey = (rhs.element.primarySubject == subjectId ? 0 : 1, rhs.element.bestRank, rhs.offset)
                return lhsKey < rhsKey
            }
            .map(\.element)
        return starters + rest
    }

    /// The catalog entry for a followed feed, so Following can show catalog subjects
    /// and artwork for sources that came from the drawer. Compares scheme, host and path
    /// case-insensitively and ignores a trailing slash; a feed that redirected to a new
    /// URL on follow won't match, which only loses the catalog tags.
    public func entry(matchingFeedURL feedURL: String) -> SourceCatalogEntry? {
        guard let key = Self.feedKey(feedURL) else { return nil }
        return entries.first { Self.feedKey($0.feedURL) == key }
    }

    static func feedKey(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        // Paths are case-sensitive (Simplecast ids are mixed case), so only scheme and host fold.
        return components.string
    }
}

public enum SourceCatalogValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(String)
    case invalidHeader
    case noUsableEntries
}

public enum SourceCatalogValidator {
    /// Returns the catalog with unusable parts removed: entries whose feed isn't https,
    /// duplicate ids or feeds, unknown subjects, and starter-row ids that no longer exist.
    /// Throws only when nothing usable is left, so one bad remote entry can't blank the drawer.
    ///
    /// Feeds are not screened with `ShareableLinkPolicy`: catalog feeds come from public
    /// directories, and the policy's heuristics flag some public feeds (Amperwave paths end in
    /// 32 hex digits). Keeping private feeds out is the catalog builder's job; once followed,
    /// the policy still decides what may leave the device.
    public static func validated(_ catalog: SourceCatalog) throws -> SourceCatalog {
        guard catalog.schemaVersion == SourceCatalog.currentSchemaVersion else {
            throw SourceCatalogValidationError.unsupportedSchemaVersion(catalog.schemaVersion)
        }
        guard catalog.contentVersion > 0,
              (1...80).contains(catalog.title.count),
              catalog.catalogId.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            throw SourceCatalogValidationError.invalidHeader
        }
        var result = catalog
        var seenSubjects = Set<String>()
        result.subjects = catalog.subjects.filter { !$0.id.isEmpty && !$0.title.isEmpty && seenSubjects.insert($0.id).inserted }
        var seenIds = Set<String>()
        var seenFeeds = Set<String>()
        result.entries = catalog.entries.compactMap { entry in
            var entry = entry
            entry.subjects = entry.subjects.filter(seenSubjects.contains)
            guard !entry.id.isEmpty,
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.subjects.isEmpty,
                  isHTTPS(entry.feedURL),
                  let feedKey = SourceCatalog.feedKey(entry.feedURL),
                  seenIds.insert(entry.id).inserted,
                  seenFeeds.insert(feedKey).inserted else { return nil }
            if let artwork = entry.artworkURL, !isHTTPS(artwork) { entry.artworkURL = nil }
            if let website = entry.websiteURL, !isHTTPS(website) { entry.websiteURL = nil }
            return entry
        }
        result.starterRows = catalog.starterRows?.compactMap { row in
            guard seenSubjects.contains(row.subjectId) else { return nil }
            var row = row
            row.entryIds = row.entryIds.filter(seenIds.contains)
            return row.entryIds.isEmpty ? nil : row
        }
        guard result.entries.contains(where: \.isFollowable) else { throw SourceCatalogValidationError.noUsableEntries }
        return result
    }

    static func isHTTPS(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw) else { return false }
        return components.scheme?.lowercased() == "https" && !(components.host ?? "").isEmpty
    }
}

/// B1 M1: whether the drawer shows a catalog entry as followed. A feed can settle on another URL
/// once followed (a redirect, or its own self link), so URL matching alone lost some follows after
/// a relaunch. An entry followed from the drawer is matched by the source id recorded when it was
/// followed; a show followed another way still matches by feed URL.
public enum CatalogFollowState {
    public static func isFollowed(
        _ entry: SourceCatalogEntry,
        in catalog: SourceCatalog,
        recordedSourceId: String?,
        subscriptions: [FeedSubscription]
    ) -> Bool {
        if let recordedSourceId, subscriptions.contains(where: { $0.source.id == recordedSourceId }) {
            return true
        }
        return subscriptions.contains { catalog.entry(matchingFeedURL: $0.source.canonicalURL)?.id == entry.id }
    }

    /// #246: the ids of every entry `isFollowed` would answer true for, in one pass. The drawer
    /// asked `isFollowed` per row per render, and each ask parsed every catalog feed URL once per
    /// subscription, which made scrolling stutter on the phone. Here each URL is parsed once.
    public static func followedEntryIds(
        in catalog: SourceCatalog,
        recordedSourceIds: [String: String],
        subscriptions: [FeedSubscription]
    ) -> Set<String> {
        let subscribedSourceIds = Set(subscriptions.map(\.source.id))
        var followed = Set(recordedSourceIds.compactMap { entryId, sourceId in
            subscribedSourceIds.contains(sourceId) ? entryId : nil
        })
        // Like `entry(matchingFeedURL:)`: a feed URL matches the first entry with that key.
        var entryIdByFeedKey: [String: String] = [:]
        for entry in catalog.entries {
            guard let key = SourceCatalog.feedKey(entry.feedURL), entryIdByFeedKey[key] == nil else { continue }
            entryIdByFeedKey[key] = entry.id
        }
        for subscription in subscriptions {
            if let key = SourceCatalog.feedKey(subscription.source.canonicalURL), let entryId = entryIdByFeedKey[key] {
                followed.insert(entryId)
            }
        }
        return followed
    }
}

/// B1 M1: when the first-run podcast drawer opens by itself. Only a fresh install sees it
/// unasked (the Library was empty before the welcome sample was added); upgraded Libraries
/// reach it from Following. It opens by itself once.
public enum FirstRunCatalogDrawerPolicy {
    public static func opensAutomatically(libraryWasEmptyAtLaunch: Bool, hasSeenDrawer: Bool, followedSourceCount: Int) -> Bool {
        libraryWasEmptyAtLaunch && !hasSeenDrawer && followedSourceCount == 0
    }
}
