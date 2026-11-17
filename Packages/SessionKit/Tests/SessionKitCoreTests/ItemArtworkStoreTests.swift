import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// The picture of each Library item (#3864): the precedence rule, https only, matching an item to its feed
/// entry, the returning-Library backfill, and the side file surviving a relaunch.
final class ItemArtworkStoreTests: XCTestCase {
    private let show = "subscription-show"
    private let showImage = "https://example.com/show.jpg"

    private func following(_ url: String? = "https://example.com/show.jpg") -> FollowingArtworkCache {
        var cache = FollowingArtworkCache()
        cache.record(feedURL: url, for: show)
        return cache
    }

    private let showName = "Test Show"

    private func key(_ id: String = "item", guid: String? = nil, url: String? = nil, show: String? = "Test Show") -> ItemArtworkStore.ItemKey {
        ItemArtworkStore.ItemKey(id: id, episodeGUID: guid, sourceURL: url, showTitle: show)
    }

    private func recorded(_ entries: [ItemArtworkStore.EntryImage]) -> ItemArtworkStore {
        var store = ItemArtworkStore()
        store.recordEntries(entries, subscriptionID: show, showTitle: showName)
        return store
    }

    // MARK: Precedence

    func testTheItemsOwnImageComesBeforeTheShowsImage() {
        let store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
    }

    func testAnItemWithNoImageOfItsOwnTakesTheShowImage() {
        let store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)])
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, showImage)
    }

    func testAnItemWithNeitherHasNoImageSoTodaysIconStays() {
        let store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)])
        XCTAssertNil(store.artworkURL(for: key(guid: "g1"), following: following(nil)))
        XCTAssertNil(ItemArtworkStore().artworkURL(for: key(guid: "g1", url: "https://example.com/e1"), following: following()),
                     "an item no followed feed lists has nothing")
    }

    func testARecordedOwnImageBeatsEveryShowImageAndARecordedSourceImageBeatsNothing() {
        var store = ItemArtworkStore()
        store.recordItem(id: "item", itemImageURL: "https://example.com/own.jpg", sourceImageURL: "https://example.com/src.jpg")
        XCTAssertEqual(store.artworkURL(for: key(), following: following())?.absoluteString, "https://example.com/own.jpg")
        store.recordItem(id: "other", sourceImageURL: "https://example.com/src.jpg")
        XCTAssertEqual(store.artworkURL(for: key("other"), following: FollowingArtworkCache())?.absoluteString, "https://example.com/src.jpg")
    }

    func testAnEntrysOwnImageBeatsARecordedSourceImage() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        store.recordItem(id: "item", sourceImageURL: "https://example.com/src.jpg")
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
    }

    func testOnlyHttpsLinksAreKept() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "http://example.com/plain.jpg")])
        XCTAssertTrue(store.entries.values.allSatisfy { $0.imageURL == nil }, "an http link is not kept")
        store.recordItem(id: "item", itemImageURL: "http://example.com/a.jpg", sourceImageURL: "/relative.jpg")
        XCTAssertNil(store.items["item"], "nothing usable, so nothing is recorded")
        XCTAssertNil(store.artworkURL(for: key(guid: "g1"), following: following(nil)))
    }

    // MARK: Matching an item to its entry

    func testAnItemMatchesItsEntryByGUIDWhateverItsAddress() {
        let store = recorded([.init(guid: "tag:ep-42", url: "https://example.com/ep-42", imageURL: "https://example.com/42.jpg")])
        XCTAssertEqual(store.artworkURL(for: key(guid: "tag:ep-42", url: "https://cdn.other.net/audio.mp3"), following: following())?.absoluteString,
                       "https://example.com/42.jpg")
        XCTAssertEqual(store.artworkURL(for: key(guid: "  tag:ep-42\n"), following: following())?.absoluteString, "https://example.com/42.jpg",
                       "whitespace around a GUID does not matter")
    }

    /// The neighbouring spellings of one page address, and look-alikes that must not match.
    func testAPostMatchesItsEntryByPageAddressTable() {
        let store = recorded([.init(guid: nil, url: "https://Example.com/Posts/One/", imageURL: "https://example.com/one.jpg")])
        let same = [
            "https://example.com/Posts/One",
            "https://EXAMPLE.com/Posts/One/",
            " https://example.com/Posts/One \n",
            "https://example.com:443/Posts/One",
            "https://example.com/Posts/One#comments",
        ]
        for address in same {
            XCTAssertEqual(store.artworkURL(for: key(url: address), following: following(nil))?.absoluteString, "https://example.com/one.jpg", address)
        }
        let different = [
            "https://example.com/posts/one",
            "https://example.com/Posts/One?utm=x",
            "https://example.com/Posts/One/two",
            "https://example.org/Posts/One",
            "http://example.com/Posts/One",
            "",
            "not a url",
        ]
        for address in different {
            XCTAssertNil(store.artworkURL(for: key(url: address), following: following(nil)), address)
        }
        XCTAssertNil(store.artworkURL(for: key(), following: following(nil)), "an item with no address matches nothing")
    }

    func testAnItemNeverShowsAnotherItemsImage() {
        let store = recorded([
            .init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg"),
            .init(guid: "g2", url: "https://example.com/e2", imageURL: "https://example.com/e2.jpg"),
        ])
        XCTAssertEqual(store.artworkURL(for: key("a", guid: "g2"), following: following())?.absoluteString, "https://example.com/e2.jpg")
        XCTAssertEqual(store.artworkURL(for: key("b", guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
        XCTAssertEqual(store.artworkURL(for: key("c", guid: "g3"), following: following())?.absoluteString, nil)
    }

    // MARK: Refresh, backfill, delete

    func testARefreshThatStopsRepeatingAnImageDoesNotEraseIt() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        store.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)], subscriptionID: show, showTitle: showName)
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
        store.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/new.jpg")], subscriptionID: show, showTitle: showName)
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/new.jpg", "a new image replaces it")
    }

    func testALibraryFromBeforeThisBuildGetsItsPicturesOnReconcileAndNoItemChanges() {
        // A store written without the side file: nothing recorded at all.
        var store = ItemArtworkStore()
        let library = [
            ItemArtworkStore.ItemKey(id: "ep", episodeGUID: "g1", sourceURL: nil, showTitle: showName),
            ItemArtworkStore.ItemKey(id: "post", episodeGUID: nil, sourceURL: "https://example.com/p"),
            ItemArtworkStore.ItemKey(id: "plain-ep", episodeGUID: "g2", sourceURL: nil, showTitle: showName),
            ItemArtworkStore.ItemKey(id: "pasted", episodeGUID: nil, sourceURL: "https://elsewhere.net/x"),
        ]
        store.recordEntries([
            .init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg"),
            .init(guid: nil, url: "https://example.com/p", imageURL: "https://example.com/p.jpg"),
            .init(guid: "g2", url: "https://example.com/e2", imageURL: nil),
        ], subscriptionID: show, showTitle: showName)
        store.reconcile(items: library, following: following())
        XCTAssertEqual(store.items["ep"], .init(feedItemImageURL: "https://example.com/e1.jpg", feedSourceImageURL: showImage))
        XCTAssertEqual(store.items["post"]?.feedItemImageURL, "https://example.com/p.jpg")
        XCTAssertEqual(store.items["plain-ep"], .init(feedItemImageURL: nil, feedSourceImageURL: showImage), "an entry with no image of its own takes the show's")
        XCTAssertNil(store.items["pasted"], "an item no followed feed lists stays on the icon: stated, not hidden")
    }

    func testAnItemKeepsItsPictureAfterTheShowIsUnfollowedAndTheEntryAgesOut() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)])
        let library = [key("ep", guid: "g1")]
        store.reconcile(items: library, following: following())
        store.removeEntries(subscriptionID: show)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.artworkURL(for: key("ep", guid: "g1"), following: FollowingArtworkCache())?.absoluteString, showImage)
    }

    func testARowReadsOnlyWhatReconcileRecorded() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil), .init(guid: "g2", url: "https://example.com/e2", imageURL: "https://example.com/e2.jpg")])
        XCTAssertNil(store.recordedArtworkURL(forItem: "a"), "nothing is recorded for an item until reconcile or recordItem")
        store.reconcile(items: [key("a", guid: "g1"), key("b", guid: "g2"), key("c")], following: following())
        XCTAssertEqual(store.recordedArtworkURL(forItem: "a")?.absoluteString, showImage)
        XCTAssertEqual(store.recordedArtworkURL(forItem: "b")?.absoluteString, "https://example.com/e2.jpg")
        XCTAssertNil(store.recordedArtworkURL(forItem: "c"))
        XCTAssertNil(store.recordedArtworkURL(forItem: "missing"))
    }

    func testDeletingAnItemRemovesItsRecord() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        store.reconcile(items: [key("a", guid: "g1"), key("b", guid: "g1")], following: following())
        XCTAssertEqual(Set(store.items.keys), ["a", "b"])
        store.reconcile(items: [key("b", guid: "g1")], following: following())
        XCTAssertEqual(Set(store.items.keys), ["b"], "a deleted item's record goes; the other's stays")
    }

    func testKeepingOnlyFollowedShowsDropsTheRestOfTheEntries() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)])
        store.recordEntries([.init(guid: "x", url: "https://other.net/x", imageURL: nil)], subscriptionID: "subscription-gone")
        store.keepEntries(forSubscriptions: [show])
        XCTAssertTrue(store.entries.values.contains { $0.subscriptionId == show })
        XCTAssertFalse(store.entries.values.contains { $0.subscriptionId == "subscription-gone" })
    }

    // MARK: Audit findings on the first version of the rule (#4418)

    /// Short numeric GUIDs are common, so two shows can share one. An item names its show, and only that show's
    /// entry can match it, whichever show refreshed last.
    func testAGUIDTwoShowsShareMatchesOnlyTheItemsOwnShow() {
        var store = ItemArtworkStore()
        store.recordEntries([.init(guid: "42", url: "https://a.example/42", imageURL: "https://a.example/42.jpg")],
                            subscriptionID: "sub-a", showTitle: "Show A")
        store.recordEntries([.init(guid: "42", url: "https://b.example/42", imageURL: "https://b.example/42.jpg")],
                            subscriptionID: "sub-b", showTitle: "Show B")
        var cache = FollowingArtworkCache()
        cache.record(feedURL: "https://a.example/show.jpg", for: "sub-a")
        cache.record(feedURL: "https://b.example/show.jpg", for: "sub-b")

        let itemA = key("a", guid: "42", show: "Show A")
        let itemB = key("b", guid: "42", show: "Show B")
        XCTAssertEqual(store.artworkURL(for: itemA, following: cache)?.absoluteString, "https://a.example/42.jpg")
        XCTAssertEqual(store.artworkURL(for: itemB, following: cache)?.absoluteString, "https://b.example/42.jpg")
        store.reconcile(items: [itemA, itemB], following: cache)
        XCTAssertEqual(store.recordedArtworkURL(forItem: "a")?.absoluteString, "https://a.example/42.jpg")
        XCTAssertEqual(store.items["a"]?.feedSourceImageURL, "https://a.example/show.jpg", "Show A's show image, not Show B's")
        XCTAssertEqual(store.recordedArtworkURL(forItem: "b")?.absoluteString, "https://b.example/42.jpg")

        // Show B is the only one followed: an item of Show A with the same GUID still takes nothing from it.
        var onlyB = ItemArtworkStore()
        onlyB.recordEntries([.init(guid: "42", url: "https://b.example/42", imageURL: "https://b.example/42.jpg")],
                            subscriptionID: "sub-b", showTitle: "Show B")
        XCTAssertNil(onlyB.artworkURL(for: itemA, following: cache))
    }

    func testAShowTitleMatchesAcrossTheWaysImportPathsWriteIt() {
        let store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        for title in ["test show", "  Test   Show ", "TEST SHOW", "<b>Test Show</b>", "Tést Show"] {
            XCTAssertEqual(store.artworkURL(for: key(guid: "g1", show: title), following: following(nil))?.absoluteString,
                           "https://example.com/e1.jpg", "\(title.debugDescription) is the same show")
        }
        for title in ["Test Show 2", "Another Show", "Test"] {
            XCTAssertNil(store.artworkURL(for: key(guid: "g1", show: title), following: following(nil)), "\(title) is another show")
        }
        var entities = ItemArtworkStore()
        entities.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")],
                               subscriptionID: show, showTitle: "Q&amp;A with Ann")
        XCTAssertNotNil(entities.artworkURL(for: key(guid: "g1", show: "Q&A with Ann"), following: following(nil)))
    }

    func testAnItemOrFeedWithNoShowTitleMatchesByAddressOnly() {
        let store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        XCTAssertNil(store.artworkURL(for: key(guid: "g1", show: nil), following: following(nil)), "a GUID alone is not an episode")
        XCTAssertNil(store.artworkURL(for: key(guid: "g1", show: ""), following: following(nil)))
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1", url: "https://example.com/e1", show: nil), following: following(nil))?.absoluteString,
                       "https://example.com/e1.jpg", "its page address still finds the entry")
        var untitled = ItemArtworkStore()
        untitled.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")], subscriptionID: show)
        XCTAssertNil(untitled.artworkURL(for: key(guid: "g1"), following: following(nil)), "a feed with no title records no GUID key")
        XCTAssertNotNil(untitled.artworkURL(for: key(url: "https://example.com/e1"), following: following(nil)))
    }

    /// The Library keys include trashed items, so a record survives the Trash and the show being unfollowed.
    func testATrashedItemKeepsItsPictureThroughAnUnfollowAndComesBackOnRestore() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        let item = key("ep", guid: "g1")
        store.reconcile(items: [item], following: following())
        store.removeEntries(subscriptionID: show)
        // While trashed the item is still listed (trashed items are in the keys), and another feed refreshes.
        store.reconcile(items: [item], following: FollowingArtworkCache())
        XCTAssertEqual(store.recordedArtworkURL(forItem: "ep")?.absoluteString, "https://example.com/e1.jpg")
        // Only an item gone for good loses its record.
        store.reconcile(items: [], following: FollowingArtworkCache())
        XCTAssertNil(store.recordedArtworkURL(forItem: "ep"))
    }

    /// A link recorded for an item directly is never replaced by what its feed knows; the feed's fill what is missing.
    func testReconcileNeverReplacesALinkRecordedForTheItem() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/feed.jpg")])
        store.recordItem(id: "ep", itemImageURL: "https://example.com/own.jpg", sourceImageURL: "https://example.com/src.jpg")
        let item = key("ep", guid: "g1")
        store.reconcile(items: [item], following: following())
        XCTAssertEqual(store.items["ep"]?.itemImageURL, "https://example.com/own.jpg")
        XCTAssertEqual(store.items["ep"]?.sourceImageURL, "https://example.com/src.jpg")
        XCTAssertEqual(store.items["ep"]?.feedItemImageURL, "https://example.com/feed.jpg")
        XCTAssertEqual(store.recordedArtworkURL(forItem: "ep")?.absoluteString, "https://example.com/own.jpg")
        XCTAssertEqual(store.artworkURL(for: item, following: following())?.absoluteString, "https://example.com/own.jpg")

        // The read order: recorded own, feed own, recorded source, feed source.
        var onlySource = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)])
        onlySource.recordItem(id: "ep", sourceImageURL: "https://example.com/src.jpg")
        onlySource.reconcile(items: [item], following: following())
        XCTAssertEqual(onlySource.recordedArtworkURL(forItem: "ep")?.absoluteString, "https://example.com/src.jpg", "recorded source beats the feed's show image")
        var feedOwn = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/feed.jpg")])
        feedOwn.recordItem(id: "ep", sourceImageURL: "https://example.com/src.jpg")
        feedOwn.reconcile(items: [item], following: following())
        XCTAssertEqual(feedOwn.recordedArtworkURL(forItem: "ep")?.absoluteString, "https://example.com/feed.jpg", "the feed's own image beats a recorded source")
    }

    func testAFeedImageIsKeptWhenALaterRefreshHasNone() {
        var store = recorded([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")])
        let item = key("ep", guid: "g1")
        store.reconcile(items: [item], following: following())
        store.removeEntries(subscriptionID: show)
        store.reconcile(items: [item], following: FollowingArtworkCache())
        XCTAssertEqual(store.recordedArtworkURL(forItem: "ep")?.absoluteString, "https://example.com/e1.jpg")
    }

    // MARK: The file

    func testTheFileSurvivesARelaunchAndIsWrittenOnlyOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ItemArtworkStore.fileName)
        XCTAssertEqual(ItemArtworkStore.fileName, "item-artwork.json")

        var artwork = ItemArtworkFile(file: file)
        artwork.update { $0.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")], subscriptionID: show, showTitle: showName) }
        artwork.update { $0.recordItem(id: "typed", itemImageURL: "https://example.com/typed.jpg") }
        let written = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("item-artwork.v1"))

        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        artwork.update { $0.recordItem(id: "typed", itemImageURL: "https://example.com/typed.jpg") }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified, "a no-change update writes nothing")

        let relaunched = ItemArtworkFile(file: file)
        XCTAssertEqual(relaunched.store, artwork.store)
        XCTAssertEqual(relaunched.store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
        XCTAssertEqual(relaunched.store.artworkURL(for: key("typed"), following: following(nil))?.absoluteString, "https://example.com/typed.jpg")

        var inMemory = ItemArtworkFile(file: nil)
        inMemory.update { $0.recordItem(id: "x", itemImageURL: "https://example.com/x.jpg") }
        XCTAssertNotNil(inMemory.store.items["x"])
    }

    func testAMissingOrUnreadableFileMeansNothingIsKnown() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ItemArtworkStore.load(from: directory.appending(path: "none.json")), ItemArtworkStore())
        let junk = directory.appending(path: "junk.json")
        try Data("not json".utf8).write(to: junk)
        XCTAssertEqual(ItemArtworkStore.load(from: junk), ItemArtworkStore())
        let future = directory.appending(path: "future.json")
        try Data(#"{"schema_version":"item-artwork.v9","items":{"a":{"item_image_url":"https://example.com/a.jpg","new_key":1}}}"#.utf8).write(to: future)
        XCTAssertEqual(ItemArtworkStore.load(from: future).items["a"]?.itemImageURL, "https://example.com/a.jpg", "unknown keys are ignored")
    }

    /// The coordinator is built on the main thread in the app, so building it must not read or decode the file (the
    /// audit of #4420): the file is gone by the time the actor first runs, and nothing it held is there.
    func testBuildingTheCoordinatorDoesNotReadTheFileAndItsFirstCallDoes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ItemArtworkStore.fileName)
        var seed = ItemArtworkFile(file: file)
        seed.update { $0.recordItem(id: "kept", itemImageURL: "https://example.com/kept.jpg") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let repository = InMemorySessionRepository()
        try repository.saveItem(Item(id: "kept", title: "Kept", mediaType: "text", text: "x", externalReference: nil, status: "ready"))

        let coordinator = FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: .ephemeral),
            artworkFile: directory.appending(path: FollowingArtworkCache.fileName), itemArtworkFile: file, signals: nil)
        try FileManager.default.removeItem(at: file)
        let store = await coordinator.itemArtwork()
        XCTAssertNil(store.recordedArtworkURL(forItem: "kept"), "nothing was read when the coordinator was built")

        // The same file, present when the first call runs, is read there.
        try seed.store.save(to: file)
        let second = FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: .ephemeral),
            artworkFile: directory.appending(path: FollowingArtworkCache.fileName), itemArtworkFile: file, signals: nil)
        let read = await second.itemArtwork()
        XCTAssertEqual(read.recordedArtworkURL(forItem: "kept")?.absoluteString, "https://example.com/kept.jpg")
    }

    func testADeferredFileReadsOnFirstUseAndOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ItemArtworkStore.fileName)
        var seed = ItemArtworkFile(file: file)
        seed.update { $0.recordItem(id: "a", itemImageURL: "https://example.com/a.jpg") }

        var deferred = ItemArtworkFile(file: file, deferringRead: true)
        XCTAssertTrue(deferred.store.items.isEmpty, "nothing is read at init")
        deferred.update { $0.recordItem(id: "b", itemImageURL: "https://example.com/b.jpg") }
        XCTAssertEqual(Set(deferred.store.items.keys), ["a", "b"], "an update reads first, so the file's items are not lost")
        XCTAssertEqual(Set(ItemArtworkFile(file: file).store.items.keys), ["a", "b"], "and the write kept them")

        var viaLoad = ItemArtworkFile(file: file, deferringRead: true)
        viaLoad.loadIfNeeded()
        XCTAssertEqual(Set(viaLoad.store.items.keys), ["a", "b"])
        try FileManager.default.removeItem(at: file)
        viaLoad.loadIfNeeded()
        XCTAssertEqual(Set(viaLoad.store.items.keys), ["a", "b"], "a second call does not read again")

        var inMemory = ItemArtworkFile(file: nil, deferringRead: true)
        inMemory.loadIfNeeded()
        XCTAssertTrue(inMemory.store.items.isEmpty)
    }

    // MARK: The coordinator writes it

    func testFollowingAndRefreshingRecordImagesForLibraryItemsAndUnfollowingKeepsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemorySessionRepository()
        // One episode already in the Library from this feed, and one pasted from elsewhere.
        for (id, guid) in [("item-ep-1", "guid-1"), ("item-ep-2", "guid-2")] {
            var episode = Item(id: id, title: id == "item-ep-1" ? "One" : "Two", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
            episode.episodeGUID = guid
            episode.showTitle = "Image Show"
            try repository.saveItem(episode)
        }
        try repository.saveItem(Item(id: "item-other", title: "Other", mediaType: "text", text: "x", externalReference: nil, status: "ready",
                                     sourceURL: "https://elsewhere.net/post"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFeedURLProtocol.self]
        let coordinator = FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: configuration),
            artworkFile: directory.appending(path: FollowingArtworkCache.fileName),
            itemArtworkFile: directory.appending(path: ItemArtworkStore.fileName), signals: nil
        )
        let subscription = try await coordinator.follow(urlString: "https://images.example/feed.xml")
        let following = await coordinator.followingArtwork()
        let store = await coordinator.itemArtwork()
        XCTAssertEqual(store.artworkURL(for: key("item-ep-1", guid: "guid-1", show: "Image Show"), following: following)?.absoluteString, "https://images.example/ep1.jpg")
        XCTAssertEqual(store.artworkURL(for: key("item-ep-2", guid: "guid-2", show: "Image Show"), following: following)?.absoluteString, "https://images.example/show.jpg",
                       "an episode with no image of its own shows the show's")
        XCTAssertNil(store.artworkURL(for: key("item-other", url: "https://elsewhere.net/post"), following: following))
        XCTAssertEqual(Set(store.items.keys), ["item-ep-1", "item-ep-2"], "the recorded picture is per Library item")

        try await coordinator.unfollow(subscriptionId: subscription.id)
        let after = ItemArtworkFile(file: directory.appending(path: ItemArtworkStore.fileName)).store
        XCTAssertTrue(after.entries.isEmpty, "the show's entries go with the follow")
        XCTAssertEqual(after.artworkURL(for: key("item-ep-1", guid: "guid-1", show: "Image Show"), following: FollowingArtworkCache())?.absoluteString,
                       "https://images.example/ep1.jpg", "the item keeps its picture after unfollowing, read back from the file")
        XCTAssertEqual(after.artworkURL(for: key("item-ep-2", guid: "guid-2", show: "Image Show"), following: FollowingArtworkCache())?.absoluteString,
                       "https://images.example/show.jpg")
        XCTAssertEqual(try repository.loadItem(id: "item-ep-1").title, "One", "no item changed")
    }
}

extension ItemArtworkStoreTests {
    /// An item from before this build, opened before any feed has refreshed: the show comes from the entries the
    /// app already stored, and the show image from the Following cache it already kept.
    func testAnItemFromBeforeThisBuildFindsItsShowFromStoredEntriesWithNoRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemorySessionRepository()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFeedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        // The earlier build: it followed the show and kept the show image, and knew nothing of item pictures.
        let earlier = FollowedSourceCoordinator(
            repository: repository, session: session,
            artworkFile: directory.appending(path: FollowingArtworkCache.fileName), signals: nil)
        _ = try await earlier.follow(urlString: "https://images.example/feed.xml")
        var episode = Item(id: "item-old", title: "Old", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
        episode.episodeGUID = "guid-2"
        episode.showTitle = "Image Show"
        try repository.saveItem(episode)

        // This build, relaunched offline: no feed is fetched, and the item file does not exist yet.
        let offline = URLSessionConfiguration.ephemeral
        offline.protocolClasses = []
        let current = FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: offline),
            artworkFile: directory.appending(path: FollowingArtworkCache.fileName),
            itemArtworkFile: directory.appending(path: ItemArtworkStore.fileName), signals: nil)
        let store = await current.itemArtwork()
        XCTAssertEqual(store.recordedArtworkURL(forItem: "item-old")?.absoluteString, "https://images.example/show.jpg")
    }
}

private final class ImageFeedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Image Show</title>
        <link>https://images.example</link><itunes:image href="https://images.example/show.jpg"/>
        <item><title>One</title><guid>guid-1</guid><link>https://images.example/1</link>
        <enclosure url="https://images.example/1.mp3" type="audio/mpeg" length="1"/><itunes:image href="https://images.example/ep1.jpg"/></item>
        <item><title>Two</title><guid>guid-2</guid><link>https://images.example/2</link>
        <enclosure url="https://images.example/2.mp3" type="audio/mpeg" length="1"/></item>
        </channel></rss>
        """.utf8)
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/rss+xml", "Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
