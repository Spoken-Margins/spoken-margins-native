import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #1792: the Library says which items hold Margins other people shared, and how many are new.
final class SharedMarginTallyTests: XCTestCase {
    private let imported = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheRowLineNamesTheCountAndWhatIsNew() {
        XCTAssertNil(SharedMarginTally.none.libraryLine)
        XCTAssertEqual(SharedMarginTally(total: 1, new: 0).libraryLine, "1 shared Margin")
        XCTAssertEqual(SharedMarginTally(total: 1, new: 1).libraryLine, "1 new shared Margin")
        XCTAssertEqual(SharedMarginTally(total: 3, new: 3).libraryLine, "3 new shared Margins")
        XCTAssertEqual(SharedMarginTally(total: 3, new: 1).libraryLine, "3 shared Margins · 1 new")
        XCTAssertEqual(SharedMarginTally(total: 3, new: 0).libraryLine, "3 shared Margins")
    }

    func testVoiceOverGetsTheWordsNotTheBadge() {
        XCTAssertNil(SharedMarginTally.none.accessibilityLine)
        XCTAssertEqual(SharedMarginTally(total: 1, new: 0).accessibilityLine, "1 Margin from other listeners")
        XCTAssertEqual(SharedMarginTally(total: 3, new: 2).accessibilityLine, "3 Margins from other listeners, 2 new to you")
    }

    func testACountNeverClaimsMoreNewThanThereAre() {
        XCTAssertEqual(SharedMarginTally(total: 2, new: 5), SharedMarginTally(total: 2, new: 2))
        XCTAssertEqual(SharedMarginTally(total: -1, new: -1), .none)
    }

    private func layer(_ id: String, item: String?, enabled: Bool = true, deleted: Bool = false, importedAt: Date? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            importedAt: importedAt ?? imported, isEnabled: enabled, deletedAt: deleted ? imported : nil
        )
    }

    private func margin(_ id: String, layer: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: id, createdAt: imported,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen to this part.",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000
        )
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")
    }

    /// Real SQLite, real packets' records: the counts come from SQL, not from decoding every Margin.
    func testTheStoreCountsEachItemsSharedMarginsAndWhichAreNew() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-tally-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        for id in ["a", "b", "c", "d", "e"] { try store.saveItem(item(id)) }
        XCTAssertEqual(try store.loadSharedMarginTallies(), [:], "nothing shared yet")

        // a: two friends, three Margins. b: a friend who is switched off still shows on the Margins screen, so it counts. c: a deleted layer. d: none.
        // e: one Margin, already heard. An unresolved layer (no item) belongs to no row.
        _ = try store.importCommentaryLayer(layer("ann", item: "a"), interjections: [margin("m1", layer: "ann"), margin("m2", layer: "ann")])
        _ = try store.importCommentaryLayer(layer("ben", item: "a"), interjections: [margin("m3", layer: "ben")])
        _ = try store.importCommentaryLayer(layer("off", item: "b", enabled: false), interjections: [margin("m4", layer: "off")])
        _ = try store.importCommentaryLayer(layer("gone", item: "c", deleted: true), interjections: [margin("m5", layer: "gone")])
        _ = try store.importCommentaryLayer(layer("kim", item: "e"), interjections: [margin("m6", layer: "kim")])
        _ = try store.importCommentaryLayer(layer("lost", item: nil), interjections: [margin("m7", layer: "lost")])
        _ = try store.markImportedCommentaryInterjectionHeard(id: "m6", at: imported)

        XCTAssertEqual(try store.loadSharedMarginTallies(), [
            "a": SharedMarginTally(total: 3, new: 3),
            "b": SharedMarginTally(total: 1, new: 1),
            "e": SharedMarginTally(total: 1, new: 0)
        ])

        _ = try store.markImportedCommentaryInterjectionHeard(id: "m2", at: imported)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadSharedMarginTallies()["a"], SharedMarginTally(total: 3, new: 2),
                       "hearing one Margin takes one off the new count, across a reopen")
    }

    /// #3469: a hidden sender's layers and a Margin hidden on its own leave the count; a layer with no sender id stays.
    func testHiddenSendersAndHiddenMarginsAreLeftOutOfTheCount() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-tally-hidden-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        for id in ["a", "b", "c"] { try store.saveItem(item(id)) }
        let ana = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ben = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        func senderLayer(_ id: String, item: String, sender: String?) -> ImportedCommentaryLayer {
            var layer = self.layer(id, item: item)
            layer.senderId = sender
            return layer
        }
        // a: Ana (two Margins) and Ben (one). b: a layer with no sender id (one). c: Ben only (one).
        _ = try store.importCommentaryLayer(senderLayer("ana", item: "a", sender: ana), interjections: [margin("m1", layer: "ana"), margin("m2", layer: "ana")])
        _ = try store.importCommentaryLayer(senderLayer("ben", item: "a", sender: ben), interjections: [margin("m3", layer: "ben")])
        _ = try store.importCommentaryLayer(senderLayer("old", item: "b", sender: nil), interjections: [margin("m4", layer: "old")])
        _ = try store.importCommentaryLayer(senderLayer("ben2", item: "c", sender: ben), interjections: [margin("m5", layer: "ben2")])

        XCTAssertEqual(try store.loadSharedMarginTallies(hiding: HiddenSenders()), try store.loadSharedMarginTallies())
        XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 3, new: 3))

        var hidden = HiddenSenders()
        hidden.hide(ben)
        XCTAssertEqual(try store.loadSharedMarginTallies(hiding: hidden), [
            "a": SharedMarginTally(total: 2, new: 2), "b": SharedMarginTally(total: 1, new: 1)
        ], "Ben's Margins are gone from both items; the layer with no sender id still counts")

        hidden.hideMargin("m1")
        XCTAssertEqual(try store.loadSharedMarginTallies(hiding: hidden), [
            "a": SharedMarginTally(total: 1, new: 1), "b": SharedMarginTally(total: 1, new: 1)
        ], "one Margin hidden on its own leaves its neighbour")

        hidden.hideMargin("m2")
        hidden.hideMargin("m4")
        XCTAssertEqual(try store.loadSharedMarginTallies(hiding: hidden), [:], "an item with nothing left has no row")

        hidden.unhide(ben)
        hidden.unhideMargin("m1")
        hidden.unhideMargin("m2")
        hidden.unhideMargin("m4")
        XCTAssertEqual(try store.loadSharedMarginTallies(hiding: hidden), try store.loadSharedMarginTallies(), "showing again brings them back")
    }

    /// The audit of #1792: matching a layer to its Margins inside a CASE made SQLite scan every layer for every
    /// Margin. The plan must find each layer by its primary key and scan the Margins once.
    func testTheCountFindsEachLayerByPrimaryKeyInsteadOfScanningLayersPerMargin() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-tally-plan-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let plan = try SQLiteSessionStore(path: path).sharedMarginTalliesQueryPlan()
        let layerSteps = plan.filter { $0.contains("layer") }
        // The primary key is (kind, id); SQLite names its index sqlite_autoindex_records_1.
        XCTAssertTrue(layerSteps.contains { $0.hasPrefix("SEARCH layer") && $0.contains("(kind=? AND id=?)") }, "plan: \(plan)")
        XCTAssertFalse(layerSteps.contains { $0.hasPrefix("SCAN") }, "plan: \(plan)")
    }

    /// #4101: Recently Added brings an item forward by when a friend's Margins arrived. Real SQLite, one grouped read.
    func testTheStoreReportsWhenTheNewestFriendMarginsArrivedPerItem() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-arrival-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        for id in ["a", "b", "c", "d", "e"] { try store.saveItem(item(id)) }
        XCTAssertEqual(try store.loadFriendMarginsArrivals(), [:], "nothing shared yet")
        let ben = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        func at(_ id: String, item: String?, seconds: TimeInterval, sender: String? = nil, deleted: Bool = false) -> ImportedCommentaryLayer {
            var layer = self.layer(id, item: item, deleted: deleted, importedAt: imported.addingTimeInterval(seconds))
            layer.senderId = sender
            return layer
        }
        // a: two friends, the later one counts. b: only a deleted layer. c: Ben, who is later hidden. d: a layer with no Margins. e: no item.
        _ = try store.importCommentaryLayer(at("ann", item: "a", seconds: 10), interjections: [margin("m1", layer: "ann")])
        _ = try store.importCommentaryLayer(at("kim", item: "a", seconds: 500), interjections: [margin("m2", layer: "kim")])
        _ = try store.importCommentaryLayer(at("gone", item: "b", seconds: 900, deleted: true), interjections: [margin("m3", layer: "gone")])
        _ = try store.importCommentaryLayer(at("ben", item: "c", seconds: 700, sender: ben), interjections: [margin("m4", layer: "ben")])
        _ = try store.importCommentaryLayer(at("empty", item: "d", seconds: 800), interjections: [])
        _ = try store.importCommentaryLayer(at("lost", item: nil, seconds: 950), interjections: [margin("m5", layer: "lost")])

        XCTAssertEqual(try store.loadFriendMarginsArrivals(), [
            "a": imported.addingTimeInterval(500), "c": imported.addingTimeInterval(700)
        ])
        var hidden = HiddenSenders()
        hidden.hide(ben)
        XCTAssertEqual(try store.loadFriendMarginsArrivals(hiding: hidden), ["a": imported.addingTimeInterval(500)],
                       "a hidden sender's arrival moves nothing")
        hidden.hideMargin("m2")
        XCTAssertEqual(try store.loadFriendMarginsArrivals(hiding: hidden), ["a": imported.addingTimeInterval(10)],
                       "a layer whose Margin is hidden no longer counts; the earlier friend does")
    }

    func testAFinishedOldItemThatGetsAFriendsPacketComesFirstInTheDefaultLibrary() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-arrival-lib-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        var october = item("october"), fresh = item("fresh")
        october.createdAt = imported.addingTimeInterval(-86_400 * 40)
        october.sourceCompletedAt = imported.addingTimeInterval(-86_400 * 30)
        fresh.createdAt = imported.addingTimeInterval(-3_600)
        try store.saveItem(october)
        try store.saveItem(fresh)
        _ = try store.importCommentaryLayer(layer("sam", item: "october"), interjections: [margin("m1", layer: "sam")])

        let snapshot = try LibraryReadSnapshot.read(store: store)
        let rows = LibraryRowBuilder.rows(from: snapshot, context: StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false))
        XCTAssertEqual(rows.first { $0.id == "october" }?.friendMarginsArrivedAt, imported)
        XCTAssertNil(rows.first { $0.id == "fresh" }?.friendMarginsArrivedAt)
        let shown = LibraryQueryEngine.visibleLibraryItems(rows, query: LibraryQuery(listeningState: .unfinished, sort: .recentlyAdded))
        XCTAssertEqual(shown.map(\.id), ["october", "fresh"], "finished, but unheard friend Margins keep it listed, and arriving puts it first")
    }

    func testTheRowBuilderPutsTheTallyOnTheItemsRow() {
        let snapshot = LibraryReadSnapshot(
            items: [item("a"), item("b")], sessions: [], manifests: [], jobs: [], downloads: [],
            sharedMarginsByItemId: ["a": SharedMarginTally(total: 2, new: 1), "gone": SharedMarginTally(total: 1, new: 1)]
        )
        let context = StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false)
        let rows = LibraryRowBuilder.rows(from: snapshot, context: context)
        XCTAssertEqual(rows.map(\.sharedMargins), [SharedMarginTally(total: 2, new: 1), .none])
    }
}
