import Foundation

/// What a followed source is and what it's about, for Following's filters (D3, #485).
public struct FollowedSourceCategory: Equatable, Hashable, Sendable {
    public var contentKind: SourceContentKind
    /// Catalog subject ids; the first is the primary one. Empty without a catalog match.
    public var subjects: [String]

    public init(contentKind: SourceContentKind, subjects: [String] = []) {
        self.contentKind = contentKind
        self.subjects = subjects
    }

    public var primarySubject: String? { subjects.first }

    /// From the source's catalog entry when there is one (I2), else from how it is followed:
    /// a podcast feed is a podcast, an article feed or website an article, with no subjects.
    public static func of(_ source: SourceIdentity, catalog: SourceCatalog?) -> FollowedSourceCategory {
        if let entry = catalog?.entry(matchingFeedURL: source.canonicalURL) {
            return FollowedSourceCategory(contentKind: entry.contentKind, subjects: entry.subjects)
        }
        return fallback(for: source)
    }

    /// `of` for every subscription, keyed by subscription id. The catalog's feed URLs are
    /// normalised once here, not once per source, so Following can call it on every render.
    public static func bySubscription(_ subscriptions: [FeedSubscription], catalog: SourceCatalog?) -> [String: FollowedSourceCategory] {
        var entries: [String: SourceCatalogEntry] = [:]
        for entry in catalog?.entries ?? [] {
            guard let key = SourceCatalog.feedKey(entry.feedURL), entries[key] == nil else { continue }
            entries[key] = entry  // the first match, as `entry(matchingFeedURL:)` finds
        }
        var result: [String: FollowedSourceCategory] = [:]
        for subscription in subscriptions {
            if let key = SourceCatalog.feedKey(subscription.source.canonicalURL), let entry = entries[key] {
                result[subscription.id] = FollowedSourceCategory(contentKind: entry.contentKind, subjects: entry.subjects)
            } else {
                result[subscription.id] = fallback(for: subscription.source)
            }
        }
        return result
    }

    private static func fallback(for source: SourceIdentity) -> FollowedSourceCategory {
        switch source.kind {
        case .podcastFeed: return FollowedSourceCategory(contentKind: .podcast)
        case .articleFeed, .website: return FollowedSourceCategory(contentKind: .article)
        }
    }
}

/// Following's kind and subject filter, plus the subjects hidden on this device.
/// With nothing chosen and nothing hidden, every entry shows, as before #485.
public struct FollowingFilter: Equatable, Sendable {
    public var kind: SourceContentKind?
    public var subject: String?
    public var hiddenSubjects: Set<String>

    public init(kind: SourceContentKind? = nil, subject: String? = nil, hiddenSubjects: Set<String> = []) {
        self.kind = kind
        self.subject = subject
        self.hiddenSubjects = hiddenSubjects
    }

    /// Whether an entry with this category shows. `nil` is an entry without a followed source
    /// (a Quick Folder file): it shows only while no kind or subject is chosen.
    /// A hidden subject hides every entry that lists it, as choosing it would show them,
    /// unless it is the subject chosen.
    public func includes(_ category: FollowedSourceCategory?) -> Bool {
        guard let category else { return kind == nil && subject == nil }
        if let kind, category.contentKind != kind { return false }
        if let subject { return category.subjects.contains(subject) }
        return hiddenSubjects.isDisjoint(with: category.subjects)
    }

    /// The kinds to offer as chips: those present, in a fixed order, then any newer kinds by name.
    public static func kinds(in categories: [FollowedSourceCategory]) -> [SourceContentKind] {
        let order: [SourceContentKind] = [.podcast, .article, .newsletter, .paper, .news, .video]
        let present = Set(categories.map(\.contentKind))
        let known = order.filter(present.contains)
        let newer = present.subtracting(order).sorted { $0.rawValue < $1.rawValue }
        return known + newer
    }

    /// The subjects to offer in the menu: those present, in the catalog's order, then any the
    /// catalog doesn't list by id.
    public static func subjects(in categories: [FollowedSourceCategory], catalog: SourceCatalog?) -> [SourceCatalogSubject] {
        let present = Set(categories.flatMap(\.subjects))
        let listed = (catalog?.subjects ?? []).filter { present.contains($0.id) }
        let listedIds = Set(listed.map(\.id))
        let unlisted = present.subtracting(listedIds).sorted().map { SourceCatalogSubject(id: $0, title: $0) }
        return listed + unlisted
    }
}
