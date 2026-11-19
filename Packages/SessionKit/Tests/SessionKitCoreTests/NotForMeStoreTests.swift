import Foundation
import XCTest
@testable import SessionKit

/// #4285 PR 3: what the listener marked "Not for me", on a real file in a real temporary directory.
final class NotForMeStoreTests: XCTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent(NotForMeStore.fileName) }
    private let clock = TickingClock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("not-for-me-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(box: NotForMeSnapshotBox = NotForMeSnapshotBox()) -> NotForMeStore {
        let clock = self.clock
        return NotForMeStore(fileURL: file, box: box, now: { clock.next() })
    }

    private let feed = "https://feeds.example/show.xml"

    // MARK: Relaunch

    func testHidesAndMarksSurviveARelaunchAndTheBoxFillsOnLoad() async throws {
        let first = makeStore()
        try await first.hideSource(catalogEntryId: "show-a", feedURL: feed, title: "Show A", artworkURL: "https://img.example/a.jpg")
        try await first.markItem(feedURL: "https://feeds.example/other.xml", guid: "g-1", canonicalURL: "https://o.example/1", audioURL: nil, title: "One")

        let box = NotForMeSnapshotBox()
        XCTAssertEqual(box.current, .empty, "nothing is published before the first load")
        let second = makeStore(box: box)
        await second.load()

        let sources = await second.hiddenSources()
        XCTAssertEqual(sources.map(\.catalogEntryId), ["show-a"])
        XCTAssertEqual(sources.first?.title, "Show A")
        XCTAssertEqual(sources.first?.artworkURL, "https://img.example/a.jpg")
        let otherKey = try XCTUnwrap(NotForMeStore.feedKey(for: "https://feeds.example/other.xml"))
        XCTAssertEqual(box.current.hiddenEntryIds, ["show-a"])
        XCTAssertEqual(box.current.hiddenFeedKeys, [try XCTUnwrap(NotForMeStore.feedKey(for: feed))])
        XCTAssertEqual(box.current.marksByFeedKey, [otherKey: 1])
        XCTAssertTrue(box.isMarked(feedKey: otherKey, entryKey: "g-1"))
        XCTAssertFalse(box.isMarked(feedKey: otherKey, entryKey: "g-2"))
    }

    func testAMissingFileIsAnEmptyStoreAndWritesNothingUntilAChange() async throws {
        let store = makeStore()
        await store.load()
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheFileIsVersionedJSONWithTheDocumentedShape() async throws {
        let store = makeStore()
        try await store.hideSource(catalogEntryId: nil, feedURL: feed, title: "Show", artworkURL: nil)
        try await store.markItem(feedURL: feed, guid: "g", canonicalURL: "https://e.example/1", audioURL: nil, title: "Ep")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let source = try XCTUnwrap((object["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(source.keys), ["feedKey", "title", "hiddenAt"], "absent optionals are left out, so an older reader sees only what it knows")
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["feedKey", "entryKey", "title", "hiddenAt"])
        XCTAssertEqual(item["entryKey"] as? String, "g")
    }

    // MARK: Unreadable files

    func testAnUnreadableFileIsSetAsideAndTheStoreStartsEmpty() async throws {
        try Data("{ not json".utf8).write(to: file)
        let store = makeStore()
        await store.load()
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, .empty)
        let aside = root.appendingPathComponent(NotForMeStore.unreadableFileName)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json", "the bytes are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // And the store works afterwards.
        try await store.hideSource(catalogEntryId: nil, feedURL: feed, title: "Show", artworkURL: nil)
        let sources = await store.hiddenSources()
        XCTAssertEqual(sources.count, 1)
    }

    func testAFileOfAnotherVersionIsSetAsideToo() async throws {
        try Data(#"{"version":2,"sources":[],"items":[]}"#.utf8).write(to: file)
        let store = makeStore()
        await store.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(NotForMeStore.unreadableFileName).path))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, .empty)
    }

    func testASecondUnreadableFileReplacesTheFirstAsideCopy() async throws {
        let aside = root.appendingPathComponent(NotForMeStore.unreadableFileName)
        try Data("first".utf8).write(to: aside)
        try Data("second".utf8).write(to: file)
        await makeStore().load()
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "second")
    }

    func testAnEmptyFileIsUnreadableNotAnEmptyStore() async throws {
        try Data().write(to: file)
        await makeStore().load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(NotForMeStore.unreadableFileName).path))
    }

    // MARK: The cap

    func testThe201stMarkOnAFeedDropsThatFeedsOldest() async throws {
        let store = makeStore()
        for n in 1...200 {
            try await store.markItem(feedURL: feed, guid: "g-\(n)", canonicalURL: nil, audioURL: nil, title: "Ep \(n)")
        }
        try await store.markItem(feedURL: "https://feeds.example/other.xml", guid: "other-1", canonicalURL: nil, audioURL: nil, title: "Other")
        var marks = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertEqual(marks.count, 200, "the other feed's mark takes nothing from this one")

        try await store.markItem(feedURL: feed, guid: "g-201", canonicalURL: nil, audioURL: nil, title: "Ep 201")
        marks = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertEqual(marks.count, 200)
        XCTAssertFalse(marks.contains { $0.entryKey == "g-1" }, "the oldest went")
        XCTAssertTrue(marks.contains { $0.entryKey == "g-2" })
        XCTAssertTrue(marks.contains { $0.entryKey == "g-201" })
        let other = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: "https://feeds.example/other.xml")))
        XCTAssertEqual(other.map(\.entryKey), ["other-1"])
        XCTAssertFalse(store.box.isMarked(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)), entryKey: "g-1"), "the box agrees")
    }

    func testMarkingAnEpisodeAgainKeepsOneMarkAndMakesItTheNewest() async throws {
        let store = makeStore()
        for n in 1...200 { try await store.markItem(feedURL: feed, guid: "g-\(n)", canonicalURL: nil, audioURL: nil, title: "Ep \(n)") }
        try await store.markItem(feedURL: feed, guid: "g-1", canonicalURL: nil, audioURL: nil, title: "Ep 1 again")
        try await store.markItem(feedURL: feed, guid: "g-201", canonicalURL: nil, audioURL: nil, title: "Ep 201")
        let marks = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertEqual(marks.count, 200)
        XCTAssertEqual(marks.filter { $0.entryKey == "g-1" }.count, 1)
        XCTAssertFalse(marks.contains { $0.entryKey == "g-2" }, "g-2 was the oldest once g-1 moved up")
    }

    func testOverTheCapOnReloadIsLeftAlone() async throws {
        // A file written by a build with a bigger cap isn't trimmed by reading it, only by the next mark.
        let key = try XCTUnwrap(NotForMeStore.feedKey(for: feed))
        let items = (1...205).map { #"{"feedKey":"\#(key)","entryKey":"g-\#($0)","title":"t","hiddenAt":"2026-11-18T00:00:00Z"}"# }
        try Data(#"{"version":1,"sources":[],"items":[\#(items.joined(separator: ","))]}"#.utf8).write(to: file)
        let store = makeStore()
        let before = await store.markedItems(feedKey: key)
        XCTAssertEqual(before.count, 205)
        try await store.markItem(feedURL: feed, guid: "new", canonicalURL: nil, audioURL: nil, title: "New")
        let after = await store.markedItems(feedKey: key)
        XCTAssertEqual(after.count, 200)
        XCTAssertTrue(after.contains { $0.entryKey == "new" })
    }

    func testMarksMadeInTheSameWholeSecondKeepTheirOrderAndTimeAfterAReload() async throws {
        let first = Date(timeIntervalSince1970: 1_800_000_000.125)
        let steps = TickingClock(start: first, step: 0.001)
        let store = NotForMeStore(fileURL: file, now: { steps.next() })
        for n in 1...3 { try await store.markItem(feedURL: feed, guid: "g-\(n)", canonicalURL: nil, audioURL: nil, title: "Ep \(n)") }

        let reloaded = makeStore()
        await reloaded.load()
        let marks = await reloaded.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertEqual(marks.map(\.entryKey), ["g-1", "g-2", "g-3"])
        XCTAssertEqual(marks.map(\.hiddenAt.timeIntervalSince1970).map { $0 - 1_800_000_000 }.map { ($0 * 1000).rounded() },
                       [126, 127, 128], "the fraction survives the file")
    }

    func testMarksWithTheSameTimestampDropTheEarlierOnesFirstOverTheCap() async throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let store = NotForMeStore(fileURL: file, now: { fixed })
        for n in 1...201 { try await store.markItem(feedURL: feed, guid: "g-\(n)", canonicalURL: nil, audioURL: nil, title: "Ep") }
        let marks = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertEqual(marks.count, 200)
        XCTAssertFalse(marks.contains { $0.entryKey == "g-1" })
        XCTAssertTrue(marks.contains { $0.entryKey == "g-201" })
    }

    func testAFileThatCantBeReadIsLeftAloneAndRefusesWritesUntilItCan() async throws {
        // A folder where the file should be: it exists, and reading it fails, like a file that isn't readable yet.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = makeStore()
        await store.load()
        let sources = await store.hiddenSources()
        XCTAssertTrue(sources.isEmpty)
        do {
            try await store.hideSource(catalogEntryId: nil, feedURL: feed, title: "A", artworkURL: nil)
            XCTFail("a write must not replace marks that were never read")
        } catch { XCTAssertEqual(error as? NotForMeStore.StoreError, .fileNotReadable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(NotForMeStore.unreadableFileName).path),
                       "a read error is not a corrupt file, so nothing is set aside")

        // The file becomes readable: the next call reads it, and the write keeps what was in it.
        try FileManager.default.removeItem(at: file)
        let key = try XCTUnwrap(NotForMeStore.feedKey(for: "https://feeds.example/earlier.xml"))
        try Data(#"{"version":1,"sources":[{"feedKey":"\#(key)","title":"Earlier","hiddenAt":"2026-11-18T00:00:00Z"}],"items":[]}"#.utf8).write(to: file)
        try await store.hideSource(catalogEntryId: nil, feedURL: feed, title: "A", artworkURL: nil)
        let after = await store.hiddenSources()
        XCTAssertEqual(Set(after.map(\.title)), ["Earlier", "A"])
    }

    // MARK: Undo and show again

    func testUndoTakesTheMarkOffByAnyKeyTheEpisodeCarries() async throws {
        let store = makeStore()
        try await store.markItem(feedURL: feed, guid: nil, canonicalURL: "https://e.example/1", audioURL: "https://e.example/1.mp3", title: "Ep")
        // Marked by page address (no GUID then); the feed now carries a GUID too.
        try await store.unmarkItem(feedURL: feed, guid: "now-has-guid", canonicalURL: "https://e.example/1", audioURL: "https://e.example/1.mp3")
        let marks = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feed)))
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(store.box.current, .empty)
    }

    func testUndoOfAnUnmarkedEpisodeChangesNothingAndWritesNothing() async throws {
        let store = makeStore()
        try await store.unmarkItem(feedURL: feed, guid: "g", canonicalURL: nil, audioURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testShowAgainTakesTheHideOffAndKeepsTheEpisodeMarks() async throws {
        let store = makeStore()
        try await store.hideSource(catalogEntryId: "show-a", feedURL: feed, title: "A", artworkURL: nil)
        try await store.markItem(feedURL: feed, guid: "g", canonicalURL: nil, audioURL: nil, title: "Ep")
        try await store.showAgain(feedURL: "HTTP://Feeds.Example/show.xml/")
        let sources = await store.hiddenSources()
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(store.box.current.hiddenEntryIds, [])
        XCTAssertEqual(store.box.current.marksByFeedKey.values.reduce(0, +), 1)
    }

    func testHidingAShowTwiceKeepsOneRecordWithTheLatestWords() async throws {
        let store = makeStore()
        try await store.hideSource(catalogEntryId: nil, feedURL: feed, title: "Old title", artworkURL: nil)
        try await store.hideSource(catalogEntryId: "show-a", feedURL: feed, title: "New title", artworkURL: nil)
        let sources = await store.hiddenSources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.title, "New title")
        XCTAssertEqual(sources.first?.catalogEntryId, "show-a")
    }

    func testAFollowedSourceIsNeverHiddenByFeedKeyOrByCatalogId() async throws {
        let store = makeStore()
        try await store.hideSource(catalogEntryId: "show-a", feedURL: feed, title: "A", artworkURL: nil)
        try await store.hideSource(catalogEntryId: "show-b", feedURL: "https://feeds.example/b.xml", title: "B", artworkURL: nil)
        try await store.hideSource(catalogEntryId: "show-c", feedURL: "https://feeds.example/c.xml", title: "C", artworkURL: nil)
        let followedKey = try XCTUnwrap(NotForMeStore.feedKey(for: "HTTP://FEEDS.example/show.xml/"))
        let dropped = try await store.removeHides(followedFeedKeys: [followedKey], followedEntryIds: ["show-b"])
        XCTAssertEqual(Set(dropped.compactMap(\.catalogEntryId)), ["show-a", "show-b"])
        let left = await store.hiddenSources()
        XCTAssertEqual(left.compactMap(\.catalogEntryId), ["show-c"])
        let none = try await store.removeHides(followedFeedKeys: [], followedEntryIds: [])
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Keys

    func testFeedKeysFoldSchemeHostCaseAndATrailingSlashButNotThePath() throws {
        let key = try XCTUnwrap(NotForMeStore.feedKey(for: "https://feeds.example/show.xml"))
        for same in ["http://feeds.example/show.xml", "HTTPS://FEEDS.EXAMPLE/show.xml", "https://feeds.example/show.xml/",
                     "  https://feeds.example/show.xml\n", "https://feeds.example/show.xml#top"] {
            XCTAssertEqual(NotForMeStore.feedKey(for: same), key, same)
        }
        for different in ["https://feeds.example/Show.xml", "https://feeds.example/show.xml?x=1", "https://other.example/show.xml"] {
            XCTAssertNotEqual(NotForMeStore.feedKey(for: different), key, different)
        }
        for unusable in ["", "   ", "not a url", "/relative/path.xml"] {
            XCTAssertNil(NotForMeStore.feedKey(for: unusable), unusable.debugDescription)
        }
    }

    func testTheSameKeyAsTheCatalogsFeedMatching() throws {
        for raw in ["https://feeds.example/a/", "http://Feeds.Example/a", "https://feeds.example/Mixed/Case"] {
            XCTAssertEqual(NotForMeStore.feedKey(for: raw), SourceCatalog.feedKey(raw), raw)
        }
    }

    func testAnEntryKeyIsTheGUIDThenThePageThenTheAudio() {
        XCTAssertEqual(NotForMeStore.entryKey(guid: "g", canonicalURL: "https://p", audioURL: "https://a"), "g")
        XCTAssertEqual(NotForMeStore.entryKey(guid: nil, canonicalURL: "https://p", audioURL: "https://a"), "https://p")
        XCTAssertEqual(NotForMeStore.entryKey(guid: "  ", canonicalURL: "", audioURL: "https://a"), "https://a")
        XCTAssertEqual(NotForMeStore.entryKey(guid: " g \n", canonicalURL: nil, audioURL: nil), "g")
        XCTAssertNil(NotForMeStore.entryKey(guid: nil, canonicalURL: " ", audioURL: ""))
        XCTAssertEqual(NotForMeStore.entryKeys(guid: "g", canonicalURL: "g", audioURL: "https://a"), ["g", "https://a"])
    }

    func testAnItemWithNoKeyAndAFeedWithNoHostAreRefusedAndWriteNothing() async throws {
        let store = makeStore()
        do {
            try await store.markItem(feedURL: feed, guid: nil, canonicalURL: "", audioURL: nil, title: "Ep")
            XCTFail("expected unidentifiableItem")
        } catch { XCTAssertEqual(error as? NotForMeStore.StoreError, .unidentifiableItem) }
        do {
            try await store.markItem(feedURL: "not a url", guid: "g", canonicalURL: nil, audioURL: nil, title: "Ep")
            XCTFail("expected unusableFeedURL")
        } catch { XCTAssertEqual(error as? NotForMeStore.StoreError, .unusableFeedURL) }
        do {
            try await store.hideSource(catalogEntryId: nil, feedURL: "", title: "Show", artworkURL: nil)
            XCTFail("expected unusableFeedURL")
        } catch { XCTAssertEqual(error as? NotForMeStore.StoreError, .unusableFeedURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: A write that fails

    func testAWriteThatFailsChangesNothingInMemoryOrInTheBox() async throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data("a file where a folder should be".utf8).write(to: blocker)
        let box = NotForMeSnapshotBox()
        let store = NotForMeStore(fileURL: blocker.appendingPathComponent(NotForMeStore.fileName), box: box)
        do {
            try await store.hideSource(catalogEntryId: "show-a", feedURL: feed, title: "A", artworkURL: nil)
            XCTFail("the write should fail")
        } catch {}
        let sources = await store.hiddenSources()
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(box.current, .empty)
    }

    func testTheBoxReadsSynchronouslyFromAnyThreadWhileTheStoreWrites() async throws {
        let box = NotForMeSnapshotBox()
        let store = makeStore(box: box)
        let feed = self.feed
        let key = try XCTUnwrap(NotForMeStore.feedKey(for: feed))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for n in 1...50 { try? await store.markItem(feedURL: feed, guid: "g-\(n)", canonicalURL: nil, audioURL: nil, title: "Ep") }
            }
            group.addTask {
                for _ in 1...500 { _ = box.current; _ = box.isMarked(feedKey: key, entryKey: "g-1") }
            }
        }
        XCTAssertEqual(box.current.marksByFeedKey[key], 50)
    }
}

/// A clock that moves one second per call, so marks have an order the cap can use.
private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0
    private let start: Date
    private let step: TimeInterval

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000), step: TimeInterval = 1) {
        self.start = start
        self.step = step
    }

    func next() -> Date {
        lock.withLock {
            ticks += 1
            return start.addingTimeInterval(step * Double(ticks))
        }
    }
}
