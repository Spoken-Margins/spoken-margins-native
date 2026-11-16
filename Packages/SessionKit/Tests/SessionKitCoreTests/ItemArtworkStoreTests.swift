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

    private func key(_ id: String = "item", guid: String? = nil, url: String? = nil) -> ItemArtworkStore.ItemKey {
        ItemArtworkStore.ItemKey(id: id, episodeGUID: guid, sourceURL: url)
    }

    private func recorded(_ entries: [ItemArtworkStore.EntryImage]) -> ItemArtworkStore {
        var store = ItemArtworkStore()
        store.recordEntries(entries, subscriptionID: show)
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
        XCTAssertNil(store.entries["guid:g1"]?.imageURL)
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
        store.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: nil)], subscriptionID: show)
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/e1.jpg")
        store.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/new.jpg")], subscriptionID: show)
        XCTAssertEqual(store.artworkURL(for: key(guid: "g1"), following: following())?.absoluteString, "https://example.com/new.jpg", "a new image replaces it")
    }

    func testALibraryFromBeforeThisBuildGetsItsPicturesOnReconcileAndNoItemChanges() {
        // A store written without the side file: nothing recorded at all.
        var store = ItemArtworkStore()
        let library = [
            ItemArtworkStore.ItemKey(id: "ep", episodeGUID: "g1", sourceURL: nil),
            ItemArtworkStore.ItemKey(id: "post", episodeGUID: nil, sourceURL: "https://example.com/p"),
            ItemArtworkStore.ItemKey(id: "plain-ep", episodeGUID: "g2", sourceURL: nil),
            ItemArtworkStore.ItemKey(id: "pasted", episodeGUID: nil, sourceURL: "https://elsewhere.net/x"),
        ]
        store.recordEntries([
            .init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg"),
            .init(guid: nil, url: "https://example.com/p", imageURL: "https://example.com/p.jpg"),
            .init(guid: "g2", url: "https://example.com/e2", imageURL: nil),
        ], subscriptionID: show)
        store.reconcile(items: library, following: following())
        XCTAssertEqual(store.items["ep"], .init(itemImageURL: "https://example.com/e1.jpg", sourceImageURL: showImage))
        XCTAssertEqual(store.items["post"]?.itemImageURL, "https://example.com/p.jpg")
        XCTAssertEqual(store.items["plain-ep"], .init(itemImageURL: nil, sourceImageURL: showImage), "an entry with no image of its own takes the show's")
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
        XCTAssertNotNil(store.entries["guid:g1"])
        XCTAssertNil(store.entries["guid:x"])
    }

    // MARK: The file

    func testTheFileSurvivesARelaunchAndIsWrittenOnlyOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ItemArtworkStore.fileName)
        XCTAssertEqual(ItemArtworkStore.fileName, "item-artwork.json")

        var artwork = ItemArtworkFile(file: file)
        artwork.update { $0.recordEntries([.init(guid: "g1", url: "https://example.com/e1", imageURL: "https://example.com/e1.jpg")], subscriptionID: show) }
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

    // MARK: The coordinator writes it

    func testFollowingAndRefreshingRecordImagesForLibraryItemsAndUnfollowingKeepsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "item-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemorySessionRepository()
        // One episode already in the Library from this feed, and one pasted from elsewhere.
        for (id, guid) in [("item-ep-1", "guid-1"), ("item-ep-2", "guid-2")] {
            var episode = Item(id: id, title: id == "item-ep-1" ? "One" : "Two", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
            episode.episodeGUID = guid
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
        XCTAssertEqual(store.artworkURL(for: key("item-ep-1", guid: "guid-1"), following: following)?.absoluteString, "https://images.example/ep1.jpg")
        XCTAssertEqual(store.artworkURL(for: key("item-ep-2", guid: "guid-2"), following: following)?.absoluteString, "https://images.example/show.jpg",
                       "an episode with no image of its own shows the show's")
        XCTAssertNil(store.artworkURL(for: key("item-other", url: "https://elsewhere.net/post"), following: following))
        XCTAssertEqual(Set(store.items.keys), ["item-ep-1", "item-ep-2"], "the recorded picture is per Library item")

        try await coordinator.unfollow(subscriptionId: subscription.id)
        let after = ItemArtworkFile(file: directory.appending(path: ItemArtworkStore.fileName)).store
        XCTAssertTrue(after.entries.isEmpty, "the show's entries go with the follow")
        XCTAssertEqual(after.artworkURL(for: key("item-ep-1", guid: "guid-1"), following: FollowingArtworkCache())?.absoluteString,
                       "https://images.example/ep1.jpg", "the item keeps its picture after unfollowing, read back from the file")
        XCTAssertEqual(after.artworkURL(for: key("item-ep-2", guid: "guid-2"), following: FollowingArtworkCache())?.absoluteString,
                       "https://images.example/show.jpg")
        XCTAssertEqual(try repository.loadItem(id: "item-ep-1").title, "One", "no item changed")
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
