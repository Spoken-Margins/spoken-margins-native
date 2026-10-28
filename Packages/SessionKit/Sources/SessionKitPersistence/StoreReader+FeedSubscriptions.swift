import Foundation
import SessionKit

/// Followed-source subscription reads for callers that are already in a `Task` (#2507). Each call decodes the whole
/// `feed_subscription` table off the caller's actor, so Following, Follow and the suggestion card no longer do it
/// on the main thread.
extension StoreReader {
    /// The key `latestFeedSubscriptions` shares between every caller that publishes the list to a screen.
    static let feedSubscriptionsKey = "feedSubscriptions"

    public func feedSubscriptions(priority: TaskPriority = .utility) async throws -> [FeedSubscription] {
        try await read(priority: priority) { try $0.loadFeedSubscriptions() }
    }

    public func feedSubscription(id: String) async throws -> FeedSubscription? {
        try await read { try $0.loadFeedSubscriptions().first { $0.id == id } }
    }

    public func feedSubscription(sourceId: String) async throws -> FeedSubscription? {
        try await read { try $0.loadFeedSubscriptions().first { $0.source.id == sourceId } }
    }

    /// For a caller that publishes the list: nil when a newer call has started, because that one publishes and an
    /// older read finishing late must not land over it.
    public func latestFeedSubscriptions() async throws -> [FeedSubscription]? {
        try await readLatest(Self.feedSubscriptionsKey) { try $0.loadFeedSubscriptions() }
    }
}
