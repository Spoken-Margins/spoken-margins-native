import Foundation

/// What a Following entry row shows beside its title (D3, #773): the show's artwork or a
/// placeholder, how long the entry takes to hear, when it was published (#1443), and the line
/// VoiceOver reads.
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
    /// The publication date for the metadata line: "Oct 12" this year, "Oct 12, 2025" before it.
    /// Always the date, never "Today"; nil when the feed gave none.
    public var dateLabel: String?
    public var accessibilityLabel: String

    /// What follows the show name on the metadata line: "12 min · Oct 12". The show name truncates
    /// before this does, so the length and date stay readable. Nil when there is neither.
    public var trailingMetadata: String? {
        let parts = [length?.label, dateLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// - Parameters:
    ///   - showTitle: the followed show's name, when known.
    ///   - artworkURL: from `FollowingArtworkCache.artworkURL(for:)`.
    ///   - rate: the listener's speech rate as a multiple of normal, for articles.
    ///   - now, calendar, locale: how the publication date is read and written. The calendar's time
    ///     zone decides which day it is, so a late-night UTC release is the listener's own day.
    public init(
        entry: FeedEntry, showTitle: String?, artworkURL: URL?, rate: Double = 1,
        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) {
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
        let published = entry.publishedAt
        dateLabel = published.map { Self.dateText($0, now: now, calendar: calendar, locale: locale, spoken: false) }
        let spokenDate = published.map { "Published " + Self.dateText($0, now: now, calendar: calendar, locale: locale, spoken: true) }
        accessibilityLabel = [show, title.nilIfEmpty, length?.spokenLabel, spokenDate]
            .compactMap { $0 }
            .map { $0.hasSuffix(".") ? $0 : "\($0)." }
            .joined(separator: " ")
    }

    /// "Oct 12" (spoken: "October 12") in the current year, with the year before that. Absolute
    /// dates only: a row that says "Today" is wrong by tomorrow, and the list is read later.
    static func dateText(_ date: Date, now: Date, calendar: Calendar, locale: Locale, spoken: Bool) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let month = spoken ? "MMMM" : "MMM"
        return FollowingDateFormatters.shared.string(
            from: date, template: sameYear ? "\(month)d" : "y\(month)d", calendar: calendar, locale: locale
        )
    }

    /// The first letter or digit, uppercased: "The Daily" gives "T", "99% Invisible" gives "9".
    static func initial(of name: String) -> String? {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() }
    }
}

/// Building a `DateFormatter` from a template is slow, and every visible Following row asks for its date
/// each time the screen redraws, so the formatters are kept per (locale, calendar, time zone, template).
final class FollowingDateFormatters: @unchecked Sendable {
    static let shared = FollowingDateFormatters()
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func string(from date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let key = [locale.identifier, "\(calendar.identifier)", calendar.timeZone.identifier, template].joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter.string(from: date)
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
