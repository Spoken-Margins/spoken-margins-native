import Foundation
import SessionKit
import SessionKitFeeds

@MainActor
enum FollowedArticleImport {
    /// A Substack post imported by a refresh, not by the listener, is read from the feed and never from its page
    /// (#2368). Without feed text it isn't imported until the listener adds it.
    static func holdsBackgroundImport(_ entry: FeedEntry, startedByListener: Bool) -> Bool {
        !startedByListener && entry.publisherPlatform == "substack" && (entry.audioURL ?? "").isEmpty
            && PublisherAudioDetector.feedBodyHandoff(for: entry) == nil
    }

    static func handoff(for entry: FeedEntry, url: URL, startedByListener: Bool = true, using extractor: any ReadablePageExtracting, record: ([String: String]) -> Void) async throws -> BrowserTextHandoff {
        if !startedByListener, entry.publisherPlatform == "substack", (entry.audioURL ?? "").isEmpty, let handoff = PublisherAudioDetector.feedBodyHandoff(for: entry) {
            record(["followedArticleExtractor": "feed_content", "followedArticleNetworkHosts": ""])
            return handoff
        }
        if let handoff = PublisherAudioDetector.articleHandoff(for: entry) {
            record(["followedArticleExtractor": "feed_content", "followedArticleNetworkHosts": ""])
            return handoff
        }
        let handoff = try await extractor.extract(url: url)
        record(["followedArticleExtractor": extractor.lastExtractor ?? "unknown",
                "followedArticleNetworkHosts": extractor.contactedHosts.joined(separator: ",")])
        return handoff
    }
}
