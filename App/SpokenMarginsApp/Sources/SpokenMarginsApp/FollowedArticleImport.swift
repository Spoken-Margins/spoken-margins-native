import Foundation
import SessionKit
import SessionKitFeeds

@MainActor
enum FollowedArticleImport {
    static func handoff(for entry: FeedEntry, url: URL, using extractor: any ReadablePageExtracting, record: ([String: String]) -> Void) async throws -> BrowserTextHandoff {
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
