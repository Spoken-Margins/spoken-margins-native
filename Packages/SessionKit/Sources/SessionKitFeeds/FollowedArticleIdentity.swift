import SessionKit

/// A followed article keeps its feed-entry identity even if extraction follows a redirect.
public enum FollowedArticleIdentity {
    public static func preservingEntryURL(in handoff: BrowserTextHandoff, for entry: FeedEntry) -> BrowserTextHandoff {
        var result = handoff
        result.source.url = entry.canonicalURL
        return result
    }
}
