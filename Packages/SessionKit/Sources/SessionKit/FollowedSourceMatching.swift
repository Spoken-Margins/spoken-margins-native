import Foundation

/// Whether a source is already followed, and which discovered feeds are new (B2). Moved out of
/// Gate1AppModel so the Follow button, the suggestion card and the tap share one host-tested rule.
public enum FollowedSourceMatching {
    /// `sourceReference` is the item's own link (an article page). With no source link, it counts
    /// as followed when a followed feed is the site feed of that link's site (#539: a Noahpinion article on
    /// www.noahpinion.blog while www.noahpinion.blog/feed was followed ran discovery again).
    public static func isSourceAlreadyFollowed(
        sourceURL: String?,
        sourceTitle: String?,
        sourceReference: String? = nil,
        subscriptions: [FeedSubscription]
    ) -> Bool {
        if let sourceURL = normalizedFollowSourceURL(sourceURL) {
            return subscriptions.contains {
                normalizedFollowSourceURL($0.source.canonicalURL) == sourceURL
            }
        }
        // An item's own source link decides on its own; the page link counts only without one.
        if subscriptions.contains(where: { isSiteFeed($0.source.canonicalURL, ofLink: sourceReference) }) {
            return true
        }
        guard let sourceTitle = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceTitle.isEmpty else { return false }
        return subscriptions.contains {
            ($0.source.title ?? $0.source.host).caseInsensitiveCompare(sourceTitle) == .orderedSame
        }
    }

    public static func isItemAlreadyFollowed(_ item: some LibraryItemFields, subscriptions: [FeedSubscription]) -> Bool {
        isSourceAlreadyFollowed(
            sourceURL: item.sourceURL, sourceTitle: item.sourceTitle,
            sourceReference: item.externalReference, subscriptions: subscriptions
        )
    }

    /// The diagnostics value for one finished discovery (#539): a feed that is already followed
    /// says so instead of looking like a new find or a failure.
    public static func discoveryDiagnostic(
        candidates: [SourceCandidateEvidence], subscriptions: [FeedSubscription]
    ) -> String {
        if candidates.isEmpty { return "none:empty" }
        if uniqueUnfollowedCandidates(candidates, subscriptions: subscriptions).isEmpty { return "already_followed" }
        return "found:\(candidates.count)"
    }

    /// The stamped diagnostics value for a discovery (#539): its `candidates`, or `failure` (such as
    /// `none:no_feed_candidates`) when it threw. A source followed by now is not a failure: it
    /// says `already_followed`.
    public static func discoveryDiagnostic(
        item: some LibraryItemFields, candidates: [SourceCandidateEvidence]?, failure: String,
        subscriptions: [FeedSubscription], at date: Date = Date()
    ) -> String {
        let value = if let candidates {
            discoveryDiagnostic(candidates: candidates, subscriptions: subscriptions)
        } else {
            isItemAlreadyFollowed(item, subscriptions: subscriptions) ? "already_followed" : failure
        }
        return stampedDiagnostic(value, at: date)
    }

    /// The discovered feeds the suggestion card may offer now: never one the listener accepted or
    /// turned off, nor one snoozed or suggested in the last 30 days.
    public static func suggestible(
        _ candidates: [SourceCandidateEvidence], now: Date,
        decision: (String) throws -> SourceSuggestionDecision?
    ) rethrows -> [SourceCandidateEvidence] {
        try candidates.filter { candidate in
            guard let decision = try decision(candidate.source.id) else { return true }
            if decision.decision == .accepted || decision.decision == .neverSuggest { return false }
            if let suppressUntil = decision.suppressUntil, suppressUntil > now { return false }
            if let lastPromptAt = decision.lastPromptAt,
               now.timeIntervalSince(lastPromptAt) < 30 * 24 * 60 * 60 { return false }
            return true
        }
    }

    /// Follow lines in exported diagnostics say when they were written (#539), so an old failure
    /// can't pass for a new one.
    public static func stampedDiagnostic(_ value: String, at date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "\(value) at=\(formatter.string(from: date))"
    }

    public static func uniqueUnfollowedCandidates(
        _ candidates: [SourceCandidateEvidence], subscriptions: [FeedSubscription]
    ) -> [SourceCandidateEvidence] {
        var sourceIDs = Set<String>()
        var urls = Set<String>()
        return candidates.filter { candidate in
            let url = normalizedFollowSourceURL(candidate.source.canonicalURL) ?? candidate.source.canonicalURL
            guard !subscriptions.contains(where: {
                $0.source.id == candidate.source.id
                    || normalizedFollowSourceURL($0.source.canonicalURL) == url
            }) else { return false }
            let newID = sourceIDs.insert(candidate.source.id).inserted
            let newURL = urls.insert(url).inserted
            return newID && newURL
        }
    }

    /// Paths of a feed that covers a whole site, not one section, author or show.
    static let siteFeedPaths: Set<String> = ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]
    /// Hosts shared by many publications, where a feed at the root never stands for one of them.
    static let sharedPublishingHosts: Set<String> = [
        "substack.com", "medium.com", "youtube.com", "podcasts.apple.com", "open.spotify.com"
    ]

    /// Whether `feedURL` is the site feed (`/feed`, `/rss`, ...) of the site `link` is on.
    /// `www.` is ignored, so example.com/feed covers www.example.com/p/post.
    static func isSiteFeed(_ feedURL: String?, ofLink link: String?) -> Bool {
        guard let feed = normalizedFollowSourceURL(feedURL).flatMap(URLComponents.init(string:)),
              let page = normalizedFollowSourceURL(link).flatMap(URLComponents.init(string:)),
              let feedHost = feed.host.map(siteHost), let pageHost = page.host.map(siteHost),
              feedHost == pageHost,
              !sharedPublishingHosts.contains(feedHost) else { return false }
        return siteFeedPaths.contains(feed.path.lowercased())
    }

    private static func siteHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func normalizedFollowSourceURL(_ value: String?) -> String? {
        guard let value,
              var components = URLComponents(
                string: value.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !scheme.isEmpty,
              !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
