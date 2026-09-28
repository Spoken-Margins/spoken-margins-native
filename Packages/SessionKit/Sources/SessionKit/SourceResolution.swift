import Foundation

// Seam I1: a pasted or shared link, or a search query, goes in; source candidates
// come out. Schema: Contracts/schemas/source-resolution.schema.json.
//
// Each resolver (Apple, Spotify, feed discovery, Substack B2, YouTube B3, bridge B4,
// catalog search) conforms to `SourceResolver` on its own and is tested on the host
// with recorded responses. `SourceResolverRegistry` runs them and merges results, so
// adding a resolver never means editing another one.

public enum SourceResolutionInput: Hashable, Sendable {
    case link(String)
    case query(String)

    public var value: String {
        switch self {
        case .link(let value), .query(let value): value
        }
    }

    /// Treats text that parses as an http(s) URL as a link, anything else as a query.
    public static func classify(_ text: String) -> SourceResolutionInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
           !(components.host ?? "").isEmpty {
            return .link(trimmed)
        }
        return .query(trimmed)
    }
}

extension SourceResolutionInput: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        switch try container.decode(String.self, forKey: .kind) {
        case "link": self = .link(value)
        case "query": self = .query(value)
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown input kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .link(let value):
            try container.encode("link", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .query(let value):
            try container.encode("query", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// How sure the resolver is. Only `exact` may be followed without asking;
/// `likely` and `possible` are shown as "Is this it?".
public enum SourceCandidateConfidence: String, Codable, Comparable, Sendable, CaseIterable {
    /// No doubt: the link is the feed itself, or a stable id maps to exactly this feed.
    case exact
    /// Strong match that a person should still confirm (exact title, same publisher).
    case likely
    /// Weak match, offered only as an option.
    case possible

    private var order: Int {
        switch self {
        case .exact: 0
        case .likely: 1
        case .possible: 2
        }
    }

    /// `exact` sorts first.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

public struct SourceCandidateFeed: Codable, Equatable, Hashable, Sendable {
    public var url: String
    /// True when the URL holds a per-subscriber secret. Private feeds never leave the
    /// device: not in packets, exports, logs or catalogs (#168).
    public private(set) var isPrivate: Bool

    /// A resolver can mark a feed private; it can never mark a feed public that
    /// `ShareableLinkPolicy` considers private.
    public init(url: String, isPrivate: Bool = false) {
        self.url = url
        self.isPrivate = isPrivate || ShareableLinkPolicy.shareableLink(url) == nil
    }

    private enum CodingKeys: String, CodingKey { case url, isPrivate }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try container.decode(String.self, forKey: .url), isPrivate: try container.decode(Bool.self, forKey: .isPrivate))
    }
}

public struct SourceCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceKind
    public var contentKind: SourceContentKind
    public var title: String
    public var author: String?
    public var artworkURL: String?
    public var websiteURL: String?
    /// Nil when the source can't be followed as a feed (for example a YouTube channel with no podcast).
    public var feed: SourceCandidateFeed?
    public var confidence: SourceCandidateConfidence
    /// Orders candidates within one confidence level. Never promotes a candidate across levels.
    public var score: Double?
    /// Shown to the listener, for example "matched by title and publish date".
    public var reason: String
    public var resolverId: String
    public var catalogEntryId: String?
    public var externalIds: SourceExternalIds?

    public init(id: String, kind: SourceKind, contentKind: SourceContentKind, title: String, author: String? = nil, artworkURL: String? = nil, websiteURL: String? = nil, feed: SourceCandidateFeed?, confidence: SourceCandidateConfidence, score: Double? = nil, reason: String, resolverId: String, catalogEntryId: String? = nil, externalIds: SourceExternalIds? = nil) {
        self.id = id
        self.kind = kind
        self.contentKind = contentKind
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.websiteURL = websiteURL
        self.feed = feed
        self.confidence = confidence
        self.score = score
        self.reason = reason
        self.resolverId = resolverId
        self.catalogEntryId = catalogEntryId
        self.externalIds = externalIds
    }

    /// True when this build can follow the candidate: it has a feed and a kind the follow path stores.
    public var isFollowable: Bool {
        feed != nil && (kind.identityKind == .podcastFeed || kind.identityKind == .articleFeed)
    }

    /// Follow in one tap only when the resolver has no doubt; otherwise ask "Is this it?".
    public var needsConfirmation: Bool { confidence != .exact }
}

public struct SourceResolutionFailure: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// One resolver's answer for one input.
public struct SourceResolution: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "source-resolution.v1"

    public var schemaVersion: String
    public var input: SourceResolutionInput
    public var resolverId: String
    public var candidates: [SourceCandidate]
    /// Set when the resolver couldn't answer, as opposed to answering "nothing matches".
    public var failure: SourceResolutionFailure?

    public init(input: SourceResolutionInput, resolverId: String, candidates: [SourceCandidate], failure: SourceResolutionFailure? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.input = input
        self.resolverId = resolverId
        self.candidates = candidates
        self.failure = failure
    }
}

public protocol SourceResolver: Sendable {
    /// Stable id, for example "apple_podcasts", "substack", "youtube_podcast_match".
    var id: String { get }
    /// Cheap and offline: whether this resolver wants to see the input at all.
    func canResolve(_ input: SourceResolutionInput) -> Bool
    /// Candidates for the input, empty when nothing matches. Throw when the resolver
    /// couldn't answer (network, rate limit); the registry records it as a failure.
    func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate]
}

public struct SourceResolverRegistry: Sendable {
    public var resolvers: [any SourceResolver]

    public init(resolvers: [any SourceResolver]) {
        self.resolvers = resolvers
    }

    /// Runs every resolver that wants the input, concurrently. Results come back in
    /// registration order; a resolver that throws yields a failure, not an error.
    public func resolve(_ input: SourceResolutionInput) async -> [SourceResolution] {
        let interested = resolvers.enumerated().filter { $0.element.canResolve(input) }
        return await withTaskGroup(of: (Int, SourceResolution).self) { group in
            for (index, resolver) in interested {
                group.addTask {
                    do {
                        return (index, SourceResolution(input: input, resolverId: resolver.id, candidates: try await resolver.resolve(input)))
                    } catch {
                        return (index, SourceResolution(
                            input: input,
                            resolverId: resolver.id,
                            candidates: [],
                            failure: SourceResolutionFailure(code: "resolver_failed", message: String(describing: error))
                        ))
                    }
                }
            }
            var results: [(Int, SourceResolution)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One list for the listener: candidates for the same feed collapse into the most
    /// confident one (ties keep the earlier resolver), then sort exact → likely →
    /// possible, by score within a level. Candidates without a feed are kept as-is.
    public static func merge(_ resolutions: [SourceResolution]) -> [SourceCandidate] {
        var merged: [SourceCandidate] = []
        var indexByFeed: [String: Int] = [:]
        for candidate in resolutions.flatMap(\.candidates) {
            guard let feed = candidate.feed, let key = SourceCatalog.feedKey(feed.url) else {
                merged.append(candidate)
                continue
            }
            if let index = indexByFeed[key] {
                var kept = merged[index]
                if candidate.confidence < kept.confidence {
                    kept = candidate
                }
                // Privacy is sticky: if any resolver saw a secret in this feed, keep it private.
                if feed.isPrivate || merged[index].feed?.isPrivate == true {
                    kept.feed = SourceCandidateFeed(url: kept.feed?.url ?? feed.url, isPrivate: true)
                }
                merged[index] = kept
            } else {
                indexByFeed[key] = merged.count
                merged.append(candidate)
            }
        }
        return merged.enumerated().sorted { lhs, rhs in
            if lhs.element.confidence != rhs.element.confidence { return lhs.element.confidence < rhs.element.confidence }
            let lhsScore = lhs.element.score ?? 0
            let rhsScore = rhs.element.score ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// Returns canned candidates. For consumers building against I1 before the real
/// resolvers exist, and for UI previews and tests.
public struct StubSourceResolver: SourceResolver {
    public let id: String
    private let responses: [SourceResolutionInput: [SourceCandidate]]

    public init(id: String = "stub", responses: [SourceResolutionInput: [SourceCandidate]]) {
        self.id = id
        self.responses = responses
    }

    /// Builds a stub from recorded resolution files (Contracts/fixtures/source-resolution).
    public init(id: String = "stub", resolutions: [SourceResolution]) {
        self.id = id
        var responses: [SourceResolutionInput: [SourceCandidate]] = [:]
        for resolution in resolutions where resolution.failure == nil {
            responses[resolution.input, default: []].append(contentsOf: resolution.candidates)
        }
        self.responses = responses
    }

    public func canResolve(_ input: SourceResolutionInput) -> Bool { responses[input] != nil }

    public func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate] { responses[input] ?? [] }
}

/// Resolves offline against the catalog: an Apple Podcasts link whose id is in the
/// catalog is `exact`; a name query matching a title is `likely` (a name alone is never
/// certain), and a title containing every query word is `possible`. The M2 search
/// resolver (iTunes Search) will sit beside this one, not replace it.
public struct CatalogSourceResolver: SourceResolver {
    public let id = "catalog"
    private let catalog: SourceCatalog

    public init(catalog: SourceCatalog) {
        self.catalog = catalog
    }

    public func canResolve(_ input: SourceResolutionInput) -> Bool {
        switch input {
        case .link(let link): Self.applePodcastsId(in: link) != nil
        case .query(let query): Self.words(query).count > 0
        }
    }

    public func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate] {
        switch input {
        case .link(let link):
            guard let appleId = Self.applePodcastsId(in: link),
                  let entry = catalog.entries.first(where: { $0.externalIds?.applePodcastsId == appleId && $0.isFollowable }) else { return [] }
            return [candidate(entry, confidence: .exact, score: 1, reason: "Apple Podcasts id \(appleId) is in the catalog")]
        case .query(let query):
            let queryWords = Self.words(query)
            guard !queryWords.isEmpty else { return [] }
            let normalizedQuery = queryWords.joined(separator: " ")
            return catalog.entries.filter(\.isFollowable).compactMap { entry -> SourceCandidate? in
                let titleWords = Self.words(entry.title)
                if titleWords.joined(separator: " ") == normalizedQuery {
                    return candidate(entry, confidence: .likely, score: 1, reason: "Title matches the search")
                }
                let titleSet = Set(titleWords)
                guard queryWords.allSatisfy(titleSet.contains) else { return nil }
                let score = Double(queryWords.count) / Double(max(titleWords.count, 1))
                return candidate(entry, confidence: .possible, score: score, reason: "Title contains every word searched")
            }
        }
    }

    private func candidate(_ entry: SourceCatalogEntry, confidence: SourceCandidateConfidence, score: Double, reason: String) -> SourceCandidate {
        SourceCandidate(
            id: "\(id):\(entry.id)",
            kind: entry.kind,
            contentKind: entry.contentKind,
            title: entry.title,
            author: entry.author,
            artworkURL: entry.artworkURL,
            websiteURL: entry.websiteURL,
            feed: SourceCandidateFeed(url: entry.feedURL),
            confidence: confidence,
            score: score,
            reason: reason,
            resolverId: id,
            catalogEntryId: entry.id,
            externalIds: entry.externalIds
        )
    }

    static func applePodcastsId(in link: String) -> String? {
        guard let components = URLComponents(string: link),
              let host = components.host?.lowercased(),
              host == "podcasts.apple.com" || host == "itunes.apple.com" else { return nil }
        for segment in components.path.split(separator: "/").reversed() where segment.hasPrefix("id") {
            let digits = segment.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "the" && $0 != "a" && $0 != "podcast" }
    }
}
