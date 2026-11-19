import XCTest
import SessionKitPersistence
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4387: the saved Following items come from the database and go on screen without a feed fetch. This reads them
/// through the same call the launch uses (`reloadFollowedSourceEntries`), with a feed that is fresh so no fetch is
/// due. `FollowingLaunchSequenceTests` (SessionKit) holds the ordering against a stalled audit and fetch.
@MainActor
final class FollowingFirstScreenTests: XCTestCase {
    func testSavedFollowingItemsAndFeedsPublishFromTheDatabaseAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "following-first-screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; see FollowingFeedListTests.
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        let now = Date()
        let source = SourceIdentity(id: "source-show", kind: .podcastFeed, canonicalURL: "https://show.example/feed", host: "show.example", title: "Show")
        try store.saveFeedSubscription(FeedSubscription(id: "show", source: source, state: .active, lastRefreshAt: now, createdAt: now))
        try store.saveFeedEntry(FeedEntry(id: "show-new", subscriptionId: "show", canonicalURL: "https://show.example/2", audioURL: "https://show.example/2.mp3", title: "Newer", publishedAt: now))
        try store.saveFeedEntry(FeedEntry(id: "show-old", subscriptionId: "show", canonicalURL: "https://show.example/1", audioURL: "https://show.example/1.mp3", title: "Older", publishedAt: now.addingTimeInterval(-3600)))

        await model.reloadFollowedSourceEntries()
        // The subscriptions are published by whichever read started last (`StoreReader.latestFeedSubscriptions` returns nil to
        // an older one), and a read begun by the model's own setup can land after this call returns, so wait for the published
        // state before asserting it (#4593). The assertions below name what is still missing if it never arrives.
        try await pollUntil { model.feedSubscriptions.map(\.id) == ["show"] && model.followedSourceEntries.count == 2 }

        XCTAssertEqual(model.followedSourceEntries.map(\.id), ["show-new", "show-old"], "newest first, as the refresh round orders them")
        XCTAssertEqual(model.feedSubscriptions.map(\.id), ["show"])
    }
}
