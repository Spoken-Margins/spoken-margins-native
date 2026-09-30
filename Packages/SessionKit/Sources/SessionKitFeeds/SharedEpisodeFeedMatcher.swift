import Foundation
import SessionKit

/// Finds the episode a shared podcast Margin belongs to in a feed the recipient pastes (#178, #452).
/// A packet from a private feed carries no link (#168), so the recipient supplies their own feed
/// and this picks the episode by identity. It never guesses: two plausible episodes are `several`.
public enum SharedEpisodeFeedMatcher {
    public enum Match: Equatable, Sendable {
        case matched(ParsedFeedItem)
        case none
        case several([ParsedFeedItem])
    }

    /// Durations further apart than this share of the longer one are different episodes.
    static let durationTolerance = 0.2

    /// True when the packet's podcast came from a private or unreachable source: the sender's
    /// links were dropped, so the recipient has to supply the episode themselves. Read from the
    /// manifest alone, so packets from Build 29 qualify without a new field.
    public static func isPrivatePodcastSource(_ manifest: SpokenMarginsPackageManifest) -> Bool {
        let item = manifest.item
        guard item.itemType == .podcast, manifest.itemTransport.kind == .recipientSupplied else { return false }
        let links = [item.canonicalURL, item.originalURL, item.enclosureURL, item.source?.canonicalURL]
        return links.allSatisfy { ($0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
    }

    public static func match(_ item: SharedItemIdentity, in feed: ParsedFeed) -> Match {
        if let guid = item.episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            let byGUID = feed.items.filter { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == guid }
            if !byGUID.isEmpty { return result(byGUID) }
            // A feed can reissue GUIDs (a host move, a re-upload); fall through to the metadata.
        }
        let title = normalizedTitle(item.title)
        guard !title.isEmpty else { return .none }
        let day = item.publishedAt.flatMap(publishDay(from:))
        let candidates = feed.items.filter { episode in
            guard normalizedTitle(episode.title) == title else { return false }
            if let day, let episodeDate = episode.publishedAt, publishDay(of: episodeDate) != day { return false }
            if let shared = item.durationMs, let episode = episode.durationMs, !durationsAgree(shared, episode) { return false }
            return true
        }
        return result(candidates)
    }

    private static func result(_ candidates: [ParsedFeedItem]) -> Match {
        switch candidates.count {
        case 0: return .none
        case 1: return .matched(candidates[0])
        default: return .several(candidates)
        }
    }

    static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func durationsAgree(_ first: Int, _ second: Int) -> Bool {
        guard first > 0, second > 0 else { return true }
        return Double(abs(first - second)) <= durationTolerance * Double(max(first, second))
    }

    private struct Day: Equatable { var year: Int; var month: Int; var day: Int }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Days are compared in UTC: both dates come from the same feed's timestamps, so the same
    /// instant lands on the same UTC day whatever the listener's time zone.
    private static func publishDay(of date: Date) -> Day {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return Day(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    private static func publishDay(from value: String) -> Day? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = ISO8601DateFormatter().date(from: trimmed) ?? withFraction.date(from: trimmed) {
            return publishDay(of: date)
        }
        let rss = DateFormatter()
        rss.locale = Locale(identifier: "en_US_POSIX")
        rss.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rss.date(from: trimmed) { return publishDay(of: date) }
        // A bare date has no time zone to convert, so it is taken as written.
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard trimmed.count == 10, parts.count == 3 else { return nil }
        return Day(year: parts[0], month: parts[1], day: parts[2])
    }
}
