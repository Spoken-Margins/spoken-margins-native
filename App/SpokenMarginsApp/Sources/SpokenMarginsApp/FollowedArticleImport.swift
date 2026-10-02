import Foundation
import SessionKit
import SessionKitFeeds

@MainActor
enum FollowedArticleImport {
    // App-only provenance: never encoded in the browser payload, Item or packets.
    enum TextSource: Equatable {
        case feedPlainText
        case extractorOutput
    }

    struct PreparedHandoff {
        let handoff: BrowserTextHandoff
        let textSource: TextSource
    }

    static func handoff(for entry: FeedEntry, url: URL, using extractor: any ReadablePageExtracting, record: ([String: String]) -> Void) async throws -> PreparedHandoff {
        if let handoff = PublisherAudioDetector.articleHandoff(for: entry) {
            record(["followedArticleExtractor": "feed_content", "followedArticleNetworkHosts": ""])
            return PreparedHandoff(handoff: handoff, textSource: .feedPlainText)
        }
        let handoff = try await extractor.extract(url: url)
        record(["followedArticleExtractor": extractor.lastExtractor ?? "unknown",
                "followedArticleNetworkHosts": extractor.contactedHosts.joined(separator: ",")])
        return PreparedHandoff(handoff: handoff, textSource: .extractorOutput)
    }
}
