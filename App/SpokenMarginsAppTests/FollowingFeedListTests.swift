import XCTest
import SessionKitPersistence
import SessionKitSharing
@testable import SessionKit
@testable import SpokenMarginsApp

/// #3343 done-when 4, below the simulator: the real model, a real store with five friends and four shows, and the rows
/// Following shows (`followingFeedRows`, the screen's own `ForEach`), so the order is checked on what the app built
/// from the database rather than on hand-made rows. `FollowingFeedTests` (SessionKit) covers the rules themselves.
@MainActor
final class FollowingFeedListTests: XCTestCase {
    func testFriendsAndShowsShareOneListNewestFirstWithQuietBelow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "following-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; see testFollowDiscoveryRechecksSubscriptionsBeforePublishing.
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        let now = Date()
        let hours = { (count: Double) in now.addingTimeInterval(-count * 3600) }
        let undated = Date(timeIntervalSince1970: 0)

        // Friends: Ada on two items, Blair's packet recorded 40 days ago but opened half an hour ago, and one friend
        // whose Margin carries no usable date.
        func shareMargin(from name: String, on itemId: String, recorded: Date, received: Date) throws {
            let layer = ImportedCommentaryLayer(
                id: "layer-\(itemId)", itemId: itemId, packageDigest: "digest-\(itemId)", packageId: "package-\(itemId)",
                itemIdentity: SharedItemIdentity(itemType: .text, title: itemId), displayLabel: name, importedAt: received
            )
            try store.saveImportedCommentaryLayer(layer)
            try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
                id: "margin-\(itemId)", layerId: layer.id, packageScopedId: "margin-001", createdAt: recorded,
                anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "\(name)'s note"
            ))
        }
        for itemId in ["ada-new", "ada-old", "blair", "cole", "shanti", "professor"] {
            try store.saveItem(Item(id: itemId, title: "On \(itemId)", mediaType: "text", text: "A passage to listen to.", externalReference: "local", status: "ready"))
        }
        try store.saveSession(Session(id: "ada-old-session", itemId: "ada-old", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "ada-old", position: Position(charOffset: 8), completionPercent: 40, playbackRate: 1))
        try shareMargin(from: "Ada", on: "ada-new", recorded: hours(1), received: hours(1))
        try shareMargin(from: "Ada", on: "ada-old", recorded: hours(72), received: hours(72))
        try shareMargin(from: "Blair", on: "blair", recorded: hours(40 * 24), received: hours(0.5))
        try shareMargin(from: "Cole", on: "cole", recorded: hours(48), received: hours(48))
        try shareMargin(from: "Shanti", on: "shanti", recorded: hours(240), received: hours(240))
        try shareMargin(from: "AI Professor", on: "professor", recorded: undated, received: undated)

        // Shows: one this morning, one five days ago, one with no episodes yet, and a Quiet one newer than them all.
        func follow(_ id: String, state: FeedSubscriptionState = .active, followed: Date, episode: Date?) throws {
            let source = SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: "Show \(id)")
            try store.saveFeedSubscription(FeedSubscription(id: id, source: source, state: state, lastRefreshAt: now, createdAt: followed))
            if let episode {
                try store.saveFeedEntry(FeedEntry(id: "\(id)-episode", subscriptionId: id, canonicalURL: "https://\(id).example/1", audioURL: "https://\(id).example/1.mp3", title: "Episode of \(id)", publishedAt: episode))
            }
        }
        try follow("morning", followed: hours(24 * 30), episode: hours(5))
        try follow("weekly", followed: hours(24 * 30), episode: hours(24 * 5))
        try follow("empty", followed: hours(24), episode: nil)
        try follow("quiet", state: .muted, followed: hours(24 * 30), episode: hours(0.1))

        model.libraryItems = try model.loadLibraryRows(store: store)
        await model.settleMarginRows()
        model.refreshMarginRows()
        try await model.publishFeedSubscriptions(store: store)
        // The "N new" markers don't decide the order; keep the test off the host app's side file.
        model.followingLookedLoaded = true

        // #3753: friends are already in memory, the shows are not. Until the first show load finishes, Following draws
        // nothing (and no empty state), so friends are never drawn first and then pushed down by newer episodes.
        let friendsBeforeLoad = model.followingFriends
        XCTAssertFalse(friendsBeforeLoad.isEmpty, "the friends are in memory before the shows load")
        XCTAssertFalse(model.followingShowListLoaded)
        XCTAssertEqual(model.followingFeedRows(friends: friendsBeforeLoad).map(\.id), [], "no friends-only first frame")
        XCTAssertFalse(model.followingShowsEmptyState(friends: []), "an unread show list is not an empty one")
        await model.reloadFollowingShowEntries()
        XCTAssertTrue(model.followingShowListLoaded)

        let friends = model.followingFriends
        let seeded: Set<String> = ["friend::ada", "friend::blair", "friend::cole", "friend::shanti", "friend::ai professor",
                                   "show::morning", "show::weekly", "show::empty", "show::quiet"]
        let rows = model.followingFeedRows(friends: friends).map(\.id).filter(seeded.contains)
        XCTContext.runActivity(named: "Following lists friends and shows together, newest first") { _ in
            XCTAssertEqual(rows, [
                "friend::blair",        // received 30 minutes ago, though recorded 40 days ago
                "friend::ada",          // 1 hour ago
                "show::morning",        // episode 5 hours ago
                "friend::cole",         // 2 days ago
                "show::weekly",         // episode 5 days ago
                "friend::shanti",       // 10 days ago
                "friend::ai professor", // no usable date
                "show::empty",          // no episodes
            ], "rows top to bottom: \(rows)")
            XCTAssertEqual(model.followingShowListCache.quiet.map(\.id), ["quiet"], "the Quiet show sits in its own section, not the list")
        }

        let ada = try XCTUnwrap(friends.first { $0.name == "Ada" })
        let blair = try XCTUnwrap(friends.first { $0.name == "Blair" })
        XCTContext.runActivity(named: "Friend rows read as #3291 left them") { _ in
            XCTAssertEqual(blair.summary, "1 Margin on 1 article")
            XCTAssertEqual(ada.summary, "2 Margins on 2 articles")
            XCTAssertEqual(blair.items.map(\.id), ["blair"], "a friend with one item opens it directly")
        }
        XCTContext.runActivity(named: "A friend with several items lists them newest first, each like a Library row") { _ in
            XCTAssertEqual(ada.items.map(\.id), ["ada-new", "ada-old"])
            XCTAssertEqual(ada.items.map(\.title), ["On ada-new", "On ada-old"])
            XCTAssertEqual(ada.items.map(\.countLabel), ["1 Margin", "1 Margin"])
            XCTAssertEqual(ada.items.map(\.newLabel), ["1 new", "1 new"], "the friend's unheard Margins are counted in words")
            // The Library row's wording after the length: source, kind, then progress.
            let details = ada.items.map { model.followingFriendItemDetail($0)?.rest }
            XCTAssertEqual(details.first??.hasSuffix("Text"), true, "each item carries the Library row's kind: \(details)")
            XCTAssertEqual(details.last??.hasSuffix("Text · 40%"), true, "progress reads as on the Library row: \(details)")
        }
    }
}
