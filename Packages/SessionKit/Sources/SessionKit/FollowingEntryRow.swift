import Foundation

/// What a Following entry row shows beside its title (D3, #773): the show's artwork or a
/// placeholder, how long the entry takes to hear, and the line VoiceOver reads.
public struct FollowingEntryRow: Equatable, Sendable {
    public enum Placeholder: Equatable, Sendable {
        /// An article without artwork: a page icon on a tinted square.
        case page
        /// A podcast without artwork: the show's first letter.
        case initial(String)
    }

    public var artworkURL: URL?
    public var placeholder: Placeholder
    public var length: ListenLength?
    public var accessibilityLabel: String

    /// - Parameters:
    ///   - showTitle: the followed show's name, when known.
    ///   - artworkURL: from `FollowingArtworkCache.artworkURL(for:)`.
    ///   - rate: the listener's speech rate as a multiple of normal, for articles.
    public init(entry: FeedEntry, showTitle: String?, artworkURL: URL?, rate: Double = 1) {
        let show = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.artworkURL = artworkURL
        self.length = ListenLength(entry, rate: rate)
        let isEpisode = !(entry.audioURL ?? "").isEmpty
        if isEpisode, let initial = Self.initial(of: show ?? entry.title) {
            placeholder = .initial(initial)
        } else {
            placeholder = .page
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        accessibilityLabel = [show, title.nilIfEmpty, length?.spokenLabel]
            .compactMap { $0 }
            .map { $0.hasSuffix(".") ? $0 : "\($0)." }
            .joined(separator: " ")
    }

    /// The first letter or digit, uppercased: "The Daily" gives "T", "99% Invisible" gives "9".
    static func initial(of name: String) -> String? {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() }
    }
}

extension FollowingArtworkCache {
    /// Records the catalog's artwork for each followed show the catalog lists, matched by feed
    /// link the way Following's subjects are (`FollowedSourceCategory.bySubscription`). Returns
    /// whether anything changed, so the caller saves the side file only then.
    @discardableResult
    public mutating func recordCatalogArtwork(for subscriptions: [FeedSubscription], catalog: SourceCatalog?) -> Bool {
        guard let catalog else { return false }
        var artworkByFeed: [String: String] = [:]
        for entry in catalog.entries {
            guard let key = SourceCatalog.feedKey(entry.feedURL), artworkByFeed[key] == nil,
                  let artwork = entry.artworkURL else { continue }
            artworkByFeed[key] = artwork
        }
        let before = self
        for subscription in subscriptions {
            guard let key = SourceCatalog.feedKey(subscription.source.canonicalURL),
                  let artwork = artworkByFeed[key] else { continue }
            record(catalogURL: artwork, for: subscription.id)
        }
        return self != before
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
