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

    private func layer(_ id: String, item: String?, enabled: Bool = true, deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            importedAt: imported, isEnabled: enabled, deletedAt: deleted ? imported : nil
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
