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

    /// Subjects that have at least one followable entry, in catalog order.
    public var visibleSubjects: [SourceCatalogSubject] {
        let used = Set(entries.filter(\.isFollowable).flatMap(\.subjects))
        return subjects.filter { used.contains($0.id) }
    }

    /// Entries for one subject chip (nil = all): the subject's starter row first,
    /// in the owner's order, then the rest by best chart rank. Only followable entries.
    public func entries(forSubject subjectId: String?) -> [SourceCatalogEntry] {
        let followable = entries.filter(\.isFollowable)
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
