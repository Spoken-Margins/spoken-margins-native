import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4101: the three doors back to an item with a friend's Margins agree. A listener who finished an episode long ago
/// imports a named friend's packet; the Library's default view lists the episode first under Recently Added, Following
/// puts the friend first, and the Margins tab's Shared list puts the episode's group first. Real SQLite, real rows.
final class FriendArrivalDoorsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rowContext = StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false)
    private var path = ""

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appending(path: "friend-doors-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private enum Finished: CaseIterable { case markedComplete, finishedSession, ninetyNinePercent }

    private func item(_ id: String, createdDaysAgo: Double) -> Item {
        var item = Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")
        item.createdAt = now.addingTimeInterval(-86_400 * createdDaysAgo)
        return item
    }

    private func finish(_ how: Finished, item: Item, in store: SQLiteSessionStore) throws {
        switch how {
        case .markedComplete:
            var marked = item
            marked.sourceCompletedAt = now.addingTimeInterval(-86_400 * 30)
            try store.saveItem(marked)
        case .finishedSession, .ninetyNinePercent:
            let done = how == .finishedSession
            try store.saveSession(Session(
                id: "heard", itemId: item.id, createdAt: now.addingTimeInterval(-86_400 * 30), updatedAt: now.addingTimeInterval(-86_400 * 30),
                completedAt: done ? now.addingTimeInterval(-86_400 * 30) : nil, status: done ? "finished" : "paused",
                phase: done ? .finished : .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id,
                position: Position(charOffset: 60), completionPercent: done ? 100 : 99, playbackRate: 1))
        }
    }

    private func importPacket(
        _ store: SQLiteSessionStore, layer id: String, friend: String?, item: String, marginIDs: [String], daysAgo: Double = 0
    ) throws {
        let layer = ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Title \(item)", durationMs: 1_800_000),
            displayLabel: friend, importedAt: now.addingTimeInterval(-86_400 * daysAgo))
        let margins = marginIDs.map { marginID in
            ImportedCommentaryInterjection(
                id: marginID, layerId: id, packageScopedId: marginID, createdAt: now.addingTimeInterval(-86_400 * 60),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 300_000), approvedTranscript: "Listen to this.",
                audioPath: "ImportedCommentary/\(marginID).m4a", audioDurationMs: 4_000)
        }
        _ = try store.importCommentaryLayer(layer, interjections: margins)
    }

    private func sharedEntries(_ store: SQLiteSessionStore) throws -> [MarginCollection.SharedEntry] {
        let titles = Dictionary(uniqueKeysWithValues: try store.listItemSummaries().map { ($0.id, $0.title) })
        return try store.loadImportedCommentaryLayers().flatMap { layer in
            try store.loadImportedCommentaryInterjections(layerId: layer.id).map {
                MarginCollection.SharedEntry(interjection: $0, layer: layer, itemTitle: layer.itemId.flatMap { titles[$0] } ?? "")
            }
        }
    }

    private func libraryRows(_ store: SQLiteSessionStore, _ query: LibraryQuery) throws -> [LibraryItemRow] {
        let rows = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: rowContext)
        return LibraryQueryEngine.visibleLibraryItems(rows, query: query)
    }

    func testAFinishedEpisodeThatGetsAFriendsPacketIsFirstInAllThreeDoors() throws {
        for how in Finished.allCases {
            let store = try SQLiteSessionStore(path: path + "-\(how)")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + "-\(how)" + suffix) } }
            try store.saveItem(item("show-a", createdDaysAgo: 0))
            try store.saveItem(item("show-b", createdDaysAgo: 0.5))
            let episode = item("episode", createdDaysAgo: 40)
            try store.saveItem(episode)
            try finish(how, item: episode, in: store)

            let before = try libraryRows(store, LibraryQuery(listeningState: .unfinished, sort: .recentlyAdded)).map(\.id)
            XCTAssertEqual(before, ["show-a", "show-b"], "\(how): finished and nothing new, so the default view leaves it out")

            try importPacket(store, layer: "sam", friend: "Sam", item: "episode", marginIDs: ["m1", "m2"])

            let library = try libraryRows(store, LibraryQuery(listeningState: .unfinished, sort: .recentlyAdded))
            XCTAssertEqual(library.map(\.id), ["episode", "show-a", "show-b"], "\(how): in the default view, first")
            XCTAssertEqual(library.first?.sharedMargins, SharedMarginTally(total: 2, new: 2))

            let entries = try sharedEntries(store)
            let friends = FollowingFriends.friends(from: entries)
            let feed = FollowingFeed.rows(friends: friends, shows: [])
            guard case .friend(let sam)? = feed.first else { return XCTFail("\(how): Following should lead with Sam, got \(feed)") }
            XCTAssertEqual(sam.name, "Sam")
            XCTAssertEqual(sam.newLabel, "2 new")

            let groups = SharedMarginGroups.groups(from: entries, libraryItemIDs: ["episode", "show-a", "show-b"])
            XCTAssertEqual(groups.first?.itemID, "episode", "\(how): the Margins tab groups the episode first")

            for id in ["m1", "m2"] { _ = try store.markImportedCommentaryInterjectionHeard(id: id, at: now) }
            XCTAssertEqual(try libraryRows(store, LibraryQuery(listeningState: .unfinished, sort: .recentlyAdded)).map(\.id),
                           ["show-a", "show-b"], "\(how): once heard, it leaves Unfinished again")
        }
    }

    func testTwoFriendsAndATwoFriendsLaterReplyKeepTheNewestArrivalFirst() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(item("fresh", createdDaysAgo: 1))
        try store.saveItem(item("one", createdDaysAgo: 40))
        try store.saveItem(item("two", createdDaysAgo: 50))
        try importPacket(store, layer: "ann", friend: "Ann", item: "one", marginIDs: ["a1"], daysAgo: 3)
        try importPacket(store, layer: "ben", friend: "Ben", item: "two", marginIDs: ["b1"], daysAgo: 2)
        XCTAssertEqual(try libraryRows(store, LibraryQuery(sort: .recentlyAdded)).map(\.id), ["fresh", "two", "one"],
                       "fresh was added a day ago, newer than either arrival; Ben's arrival is newer than Ann's")
        try importPacket(store, layer: "ann-2", friend: "Ann", item: "one", marginIDs: ["a2"], daysAgo: 0)
        XCTAssertEqual(try libraryRows(store, LibraryQuery(sort: .recentlyAdded)).map(\.id), ["one", "fresh", "two"])
    }

    func testAnEmptyLibraryAndAnItemWithOnlyHeardMarginsDoNotMove() throws {
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try libraryRows(store, LibraryQuery(sort: .recentlyAdded)).map(\.id), [])
        try store.saveItem(item("fresh", createdDaysAgo: 1))
        try store.saveItem(item("old", createdDaysAgo: 40))
        try importPacket(store, layer: "sam", friend: "Sam", item: "old", marginIDs: ["m1"], daysAgo: 10)
        XCTAssertEqual(try libraryRows(store, LibraryQuery(sort: .recentlyAdded)).map(\.id), ["fresh", "old"],
                       "an arrival older than the other item's add date does not jump it")
    }
}
