import Foundation

// Seam I3: the bridge manifest. One document, identical for every install, listing
// sites that publish no feed, their latest article links and a fetch recipe. The
// phone downloads all of it and keeps the sources the listener follows, so the
// server never learns a follow list; it fetches each article from the publisher
// itself. Server side and privacy rules: research/B4/DESIGN.md §5–6.
//
// The server's publish gate is strict. This side is lenient about new fields (old
// builds keep working as the format grows) but drops anything it must not act on.

public struct BridgeManifest: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.bridge-manifest"
    public static let version = 1

    public var schema: String
    public var version: Int
    public var generatedAt: String
    public var sources: [BridgeSource]

    public init(generatedAt: String, sources: [BridgeSource]) {
        self.schema = Self.schema
        self.version = Self.version
        self.generatedAt = generatedAt
        self.sources = sources
    }

    public func source(id: String) -> BridgeSource? { sources.first { $0.id == id } }

    /// The source a shared link belongs to, decided on the phone so checking
    /// "can I follow this?" asks the server nothing.
    public func source(matching link: URL) -> BridgeSource? {
        sources.first { $0.status != .retired && $0.matches(link) }
    }
}

public struct BridgeSource: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case active, paused, retired

        public init(from decoder: Decoder) throws {
            // An unknown status from a newer server is treated as paused: shown, not updated.
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .paused
        }
    }

    public struct Match: Codable, Equatable, Sendable {
        public var hosts: [String]
        public var pathPrefixes: [String]?

        public init(hosts: [String], pathPrefixes: [String]? = nil) {
            self.hosts = hosts
            self.pathPrefixes = pathPrefixes
        }
    }

    public var id: String
    public var title: String
    public var homepage: String
    public var match: Match
    public var status: Status
    public var checkedAt: String
    /// Changes when the item list changes: the per-source change marker.
    public var updatedAt: String
    public var items: [BridgeItem]
    public var recipe: BridgeRecipe

    public init(id: String, title: String, homepage: String, match: Match, status: Status = .active, checkedAt: String, updatedAt: String, items: [BridgeItem], recipe: BridgeRecipe) {
        self.id = id
        self.title = title
        self.homepage = homepage
        self.match = match
        self.status = status
        self.checkedAt = checkedAt
        self.updatedAt = updatedAt
        self.items = items
        self.recipe = recipe
    }

    public func matches(_ link: URL) -> Bool {
        guard link.scheme?.lowercased() == "https", let host = link.host?.lowercased(),
              match.hosts.contains(host) else { return false }
        guard let prefixes = match.pathPrefixes, !prefixes.isEmpty else { return true }
        let path = link.path.isEmpty ? "/" : link.path
        return prefixes.contains { path.hasPrefix($0) }
    }
}

/// A link and its metadata. There is deliberately nowhere to put article text: the
/// server never serves bodies.
public struct BridgeItem: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var publishedAt: String?
    public var firstSeenAt: String

    public init(url: String, title: String, publishedAt: String? = nil, firstSeenAt: String) {
        self.url = url
        self.title = title
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
    }
}

/// How the phone extracts an article: data in a closed vocabulary, never code (App
/// Store Guideline 2.5.2). Selectors must reach a page only as arguments to
/// `callAsyncJavaScript(_:arguments:in:contentWorld:)`, never spliced into script.
public struct BridgeRecipe: Codable, Equatable, Sendable {
    public static let supportedVersion = 1

    public enum Extract: String, Codable, Sendable {
        /// The bundled readability extractor.
        case readable
        /// The selector lists below, applied with querySelectorAll.
        case selectors
    }

    public struct Attribute: Codable, Equatable, Sendable {
        public var selector: String
        public var attribute: String?
    }

    public var version: Int
    public var extract: Extract
    public var content: [String]?
    public var remove: [String]?
    public var title: String?
    public var published: Attribute?

    public static let readable = BridgeRecipe(version: supportedVersion, extract: .readable)

    public init(version: Int, extract: Extract, content: [String]? = nil, remove: [String]? = nil, title: String? = nil, published: Attribute? = nil) {
        self.version = version
        self.extract = extract
        self.content = content
        self.remove = remove
        self.title = title
        self.published = published
    }

    private enum CodingKeys: String, CodingKey { case version, extract, content, remove, title, published }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // An extract mode this build doesn't know becomes "readable" in sanitizing below.
        extract = (try? c.decode(Extract.self, forKey: .extract)) ?? .readable
        content = try c.decodeIfPresent([String].self, forKey: .content)
        remove = try c.decodeIfPresent([String].self, forKey: .remove)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        published = try c.decodeIfPresent(Attribute.self, forKey: .published)
    }
}

public enum BridgeManifestError: Error, Equatable, Sendable {
    case oversized
    case malformed
}

public enum BridgeManifestVerifier {
    public static let maximumBytes = 4 * 1_024 * 1_024
    public static let maximumSelectors = 10
    public static let maximumSelectorLength = 200
    /// Our own domains are never a source host: a phone following such a source would
    /// fetch from us and tell us who follows it (DESIGN §5).
    public static let ownDomains = ["proximitytoprogress.com", "spokenmargins.com", "spokenmargins.app"]
    private static let selectorForbidden = ["{", "}", ";", "<", "`", "\\", "/*", "*/", "url(", "expression(", "javascript:", "@import"]

    /// Decodes a manifest and drops what the phone must not act on. Throws only when
    /// the document as a whole is unusable.
    public static func manifest(from data: Data) throws -> BridgeManifest {
        guard data.count <= maximumBytes else { throw BridgeManifestError.oversized }
        guard let decoded = try? JSONDecoder().decode(BridgeManifest.self, from: data),
              decoded.schema == BridgeManifest.schema,
              decoded.version == BridgeManifest.version else {
            throw BridgeManifestError.malformed
        }
        return sanitized(decoded)
    }

    public static func sanitized(_ manifest: BridgeManifest) -> BridgeManifest {
        var seen = Set<String>()
        var out = manifest
        out.sources = manifest.sources.compactMap { source -> BridgeSource? in
            guard !source.id.isEmpty, seen.insert(source.id).inserted else { return nil }
            var source = source
            source.match.hosts = source.match.hosts.map { $0.lowercased() }
            guard !source.match.hosts.isEmpty, source.match.hosts.allSatisfy(isAllowedHost) else { return nil }
            guard isOnSourceHost(source.homepage, source) else { return nil }
            source.items = source.items.filter { isOnSourceHost($0.url, source) && !$0.title.isEmpty }
            source.recipe = sanitized(source.recipe)
            return source
        }
        return out
    }

    /// A recipe this build can't fully honour falls back to the bundled readability
    /// extractor rather than guessing.
    public static func sanitized(_ recipe: BridgeRecipe) -> BridgeRecipe {
        guard recipe.version == BridgeRecipe.supportedVersion else { return .readable }
        let lists = [recipe.content ?? [], recipe.remove ?? []]
        let singles = [recipe.title, recipe.published?.selector].compactMap { $0 }
        guard lists.allSatisfy({ $0.count <= maximumSelectors }),
              (lists.flatMap { $0 } + singles).allSatisfy(isSafeSelector) else { return .readable }
        if let attribute = recipe.published?.attribute,
           attribute.range(of: "^[a-z][a-z0-9-]{0,40}$", options: .regularExpression) == nil {
            return .readable
        }
        if recipe.extract == .selectors, (recipe.content ?? []).isEmpty { return .readable }
        return recipe
    }

    static func isAllowedHost(_ host: String) -> Bool {
        guard host.range(of: "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", options: .regularExpression) != nil else {
            return false
        }
        return !ownDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isOnSourceHost(_ string: String, _ source: BridgeSource) -> Bool {
        guard string.count <= 2_048, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return source.match.hosts.contains(host)
    }

    static func isSafeSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= maximumSelectorLength,
              !selector.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let lower = selector.lowercased()
        return !selectorForbidden.contains { lower.contains($0) }
    }
}
