import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4289: since #4101 a finished item with a friend's new Margins stays under the Library's Unfinished view, and nothing
/// but playing every Margin cleared it. "Mark Margins Heard" is the second mark complete. Real SQLite, real Library rows.
final class ItemMarginsHeardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rowContext = StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false)
    private var path = ""

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appending(path: "margins-heard-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func finishedItem(_ id: String, in store: SQLiteSessionStore) throws {
        var item = Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")
        item.createdAt = now.addingTimeInterval(-86_400 * 40)
        item.sourceCompletedAt = now.addingTimeInterval(-86_400 * 30)
        try store.saveItem(item)
    }

    private func importPacket(_ store: SQLiteSessionStore, layer id: String, sender: String?, item: String, margins ids: [String]) throws {
        var layer = ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Title \(item)", durationMs: 1_800_000),
            displayLabel: "Sam", importedAt: now)
        layer.senderId = sender
        let margins = ids.map {
            ImportedCommentaryInterjection(
                id: $0, layerId: id, packageScopedId: $0, createdAt: now,
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 300_000), approvedTranscript: "Listen to this.",
                audioPath: "ImportedCommentary/\($0).m4a", audioDurationMs: 4_000)
        }
        _ = try store.importCommentaryLayer(layer, interjections: margins)
    }

    private func unfinishedIDs(_ store: SQLiteSessionStore, hiding hidden: HiddenSenders = HiddenSenders()) throws -> [String] {
        let rows = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store, hiddenSenders: hidden), context: rowContext)
        return LibraryQueryEngine.visibleLibraryItems(rows, query: LibraryQuery(listeningState: .unfinished)).map(\.id)
    }

    func testMarkingTheMarginsHeardLetsAFinishedItemLeaveUnfinishedAndKeepsEveryMargin() throws {
        do {
            let store = try SQLiteSessionStore(path: path)
            try finishedItem("episode", in: store)
            try importPacket(store, layer: "sam", sender: nil, item: "episode", margins: ["m1", "m2"])
            XCTAssertEqual(try unfinishedIDs(store), ["episode"], "#4101: unheard friend Margins keep it findable")
            XCTAssertEqual(
                ItemQuickAction.completionAction(for: try XCTUnwrap(
                    LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: rowContext).first)),
                .markMarginsHeard)

            XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "episode", at: now, in: store), 2)
            XCTAssertEqual(try unfinishedIDs(store), [], "the second mark complete clears it")
        }
        // A relaunch: the heard time is stored, and nothing was removed.
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try unfinishedIDs(store), [])
        let layers = try store.loadImportedCommentaryLayers(itemId: "episode")
        XCTAssertEqual(layers.count, 1)
        XCTAssertNil(layers.first?.deletedAt)
        let margins = try store.loadImportedCommentaryInterjections(layerId: "sam")
        XCTAssertEqual(margins.map(\.id).sorted(), ["m1", "m2"])
        XCTAssertEqual(margins.compactMap(\.firstHeardAt), [now, now])
        XCTAssertTrue(margins.allSatisfy { $0.audioPath != nil }, "the recordings stay playable")
        XCTAssertNotNil(try store.loadItem(id: "episode").sourceCompletedAt, "the item's own completion is untouched")
    }

    func testItKeepsAnEarlierHeardTimeAndNeverTouchesAnotherItem() throws {
        let store = try SQLiteSessionStore(path: path)
        try finishedItem("episode", in: store)
        try finishedItem("other", in: store)
        try importPacket(store, layer: "sam", sender: nil, item: "episode", margins: ["m1", "m2"])
        try importPacket(store, layer: "ann", sender: nil, item: "other", margins: ["o1"])
        let earlier = now.addingTimeInterval(-3_600)
        _ = try store.markImportedCommentaryInterjectionHeard(id: "m1", at: earlier)

        XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "episode", at: now, in: store), 1, "only the one still new")
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "sam").first { $0.id == "m1" }?.firstHeardAt, earlier)
        XCTAssertEqual(try unfinishedIDs(store), ["other"], "the other item's Margins are still new")
        XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "episode", at: now, in: store), 0, "nothing left to mark")
    }

    func testAHiddenSendersMarginsAreLeftAloneSoUnhidingThemStillShowsThemNew() throws {
        let store = try SQLiteSessionStore(path: path)
        try finishedItem("episode", in: store)
        try importPacket(store, layer: "sam", sender: "sender-sam-0000000000000000", item: "episode", margins: ["m1"])
        try importPacket(store, layer: "ann", sender: "sender-ann-0000000000000000", item: "episode", margins: ["a1"])
        var hidden = HiddenSenders()
        XCTAssertTrue(hidden.hide("sender-ann-0000000000000000", displayLabel: "Ann", at: now))
        XCTAssertTrue(hidden.hideMargin("m1", senderLabel: "Sam", text: "Listen to this.", at: now))

        XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "episode", at: now, hiding: hidden, in: store), 0)
        XCTAssertEqual(try unfinishedIDs(store, hiding: hidden), [], "Ann is hidden and m1 is hidden on its own, so nothing counts as new")
        XCTAssertEqual(try unfinishedIDs(store, hiding: HiddenSenders()), ["episode"], "brought back, they are still new")
    }

    func testAnItemWithNoSharedMarginsMarksNothing() throws {
        let store = try SQLiteSessionStore(path: path)
        try finishedItem("episode", in: store)
        XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "episode", in: store), 0)
        XCTAssertEqual(try ItemMarginsHeard.markHeard(itemId: "missing", in: store), 0)
    }
}
