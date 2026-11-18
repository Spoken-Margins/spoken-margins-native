import Foundation
import XCTest
@testable import SessionKit

/// #4343: the Library narrows by a collection with the same type the Margins tab uses.
final class LibraryCollectionScopeTests: XCTestCase {
    private struct Row: LibraryQueryRow {
        var id: String
        var title = "Title"
        var sourceTitle: String?
        var author: String?
        var mediaType = "text"
        var sourceReference: String?
        var sourceReferenceType: String?
        var isCompleted = false
        var continuationProgressPercent: Int?
        var offlineState: LibraryOfflineStateFilter = .onlineOnly
        var addedAt: Date?
        var publishedAt: Date?
        var lastListenedAt: Date?
        var storageRecencyRank = Int.max
        var sharedMargins = SharedMarginTally.none
        var friendMarginsArrivedAt: Date?
    }

    private func rows(_ ids: String...) -> [Row] { ids.map { Row(id: $0) } }
    private func collection(_ id: String, _ members: [String], name: String? = nil) -> ItemCollection {
        ItemCollection(id: id, name: name ?? id, itemIDs: members, createdAt: Date(timeIntervalSince1970: 1))
    }
    private func ids(_ rows: [Row]) -> [String] { rows.map(\.id) }

    func testAllListsEveryRowInItsOwnOrder() {
        let library = rows("c", "a", "b")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: nil)), ["c", "a", "b"])
    }

    func testACollectionListsOnlyItsMembersInTheLibrarysOrderNotTheCollectionsOrder() {
        let course = collection("course", ["b", "a"])
        let library = rows("a", "x", "b", "y")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: ItemCollectionScope(course))), ["a", "b"])
    }

    func testAnEmptyCollectionListsNothingAndCountsZero() {
        let empty = collection("empty", [])
        let library = rows("a", "b")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: ItemCollectionScope(empty))), [])
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: empty, among: library), 0)
    }

    func testADeletedSelectedCollectionFallsBackToAll() {
        let course = collection("course", ["a"])
        let selected = ItemCollectionScope(course)
        XCTAssertNil(LibraryCollectionScope.selection(selected, afterCollectionsChanged: [collection("club", ["b"])]))
        XCTAssertNil(LibraryCollectionScope.selection(selected, afterCollectionsChanged: []))
        XCTAssertNil(LibraryCollectionScope.selection(nil, afterCollectionsChanged: [course]))
    }

    func testTheSelectionPicksUpMembersAddedAfterItWasMade() {
        var course = collection("course", ["a"])
        let selected = ItemCollectionScope(course)
        course.itemIDs = ["a", "b"]
        let refreshed = LibraryCollectionScope.selection(selected, afterCollectionsChanged: [course])
        XCTAssertEqual(ids(LibraryCollectionScope.rows(rows("a", "b", "c"), in: refreshed)), ["a", "b"])
        XCTAssertEqual(ids(LibraryCollectionScope.rows(rows("a", "b", "c"), in: selected)), ["a"], "the old selection is a snapshot")
    }

    func testAChipTapFindsTheCollectionOrFallsBackToAll() {
        let collections = [collection("course", ["a"]), collection("club", ["b"])]
        XCTAssertEqual(LibraryCollectionScope.selection(collectionID: "club", in: collections)?.collectionID, "club")
        XCTAssertNil(LibraryCollectionScope.selection(collectionID: "gone", in: collections))
        XCTAssertNil(LibraryCollectionScope.selection(collectionID: nil, in: collections))
    }

    func testAnItemInTwoCollectionsIsListedAndCountedInBoth() {
        let course = collection("course", ["shared", "only-course"])
        let club = collection("club", ["shared"])
        let library = rows("shared", "only-course")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: ItemCollectionScope(course))), ["shared", "only-course"])
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: ItemCollectionScope(club))), ["shared"])
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: course, among: library), 2)
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: club, among: library), 1)
    }

    func testATrashedMemberIsNotCountedOrListedAndComesBackWhenRestored() {
        let course = collection("course", ["a", "trashed", "b"])
        let withoutTrashed = rows("a", "b")
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: course, among: withoutTrashed), 2, "not itemIDs.count, which is 3")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(withoutTrashed, in: ItemCollectionScope(course))), ["a", "b"])

        let restored = rows("a", "trashed", "b")
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: course, among: restored), 3)
        XCTAssertEqual(ids(LibraryCollectionScope.rows(restored, in: ItemCollectionScope(course))), ["a", "trashed", "b"])
    }

    func testCompletedMembersCountEvenWhenTheListeningFilterHidesThem() {
        let course = collection("course", ["open", "done"])
        let library = [Row(id: "open"), Row(id: "done", isCompleted: true)]
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: course, among: library), 2)
        let unfinished = LibraryCollectionScope.visibleLibraryItems(library, query: LibraryQuery(listeningState: .unfinished), in: ItemCollectionScope(course))
        XCTAssertEqual(ids(unfinished), ["open"])
        let all = LibraryCollectionScope.visibleLibraryItems(library, query: LibraryQuery(listeningState: .all), in: ItemCollectionScope(course))
        XCTAssertEqual(Set(ids(all)), ["open", "done"])
    }

    func testSearchNarrowsInsideTheCollectionAndNeverPastIt() {
        let library = [
            Row(id: "in", title: "Roman roads"),
            Row(id: "also-in", title: "Greek temples"),
            Row(id: "out", title: "Roman baths"),
        ]
        let course = collection("course", ["in", "also-in"])
        let selection = ItemCollectionScope(course)
        let query = LibraryQuery(query: "roman", listeningState: .all)
        XCTAssertEqual(ids(LibraryCollectionScope.visibleLibraryItems(library, query: query, in: selection)), ["in"])
        XCTAssertEqual(Set(ids(LibraryCollectionScope.visibleLibraryItems(library, query: query, in: nil))), ["in", "out"])
    }

    func testAllWithNoCollectionMatchesTheEngineExactly() {
        let library = [Row(id: "b", title: "B", isCompleted: true), Row(id: "a", title: "A"), Row(id: "c", title: "C")]
        for state in [LibraryListeningStateFilter.all, .unfinished, .completed] {
            let query = LibraryQuery(listeningState: state, sort: .title)
            XCTAssertEqual(
                ids(LibraryCollectionScope.visibleLibraryItems(library, query: query, in: nil)),
                ids(LibraryQueryEngine.visibleLibraryItems(library, query: query))
            )
        }
    }

    func testTheChipRowShowsFromFifteenItemsOrOnceAnyCollectionExists() {
        XCTAssertFalse(CollectionChipRule.showsRow(itemCount: 14, collectionCount: 0))
        XCTAssertTrue(CollectionChipRule.showsRow(itemCount: 15, collectionCount: 0))
        XCTAssertTrue(CollectionChipRule.showsRow(itemCount: 16, collectionCount: 0))
        XCTAssertTrue(CollectionChipRule.showsRow(itemCount: 0, collectionCount: 1), "even an empty library with one collection")
        XCTAssertTrue(CollectionChipRule.showsRow(itemCount: 3, collectionCount: 2))
        XCTAssertFalse(CollectionChipRule.showsRow(itemCount: 0, collectionCount: 0))
    }

    func testChipsAreAlphabeticalLocalizedAndCaseInsensitiveWithTiesByID() {
        let collections = [
            collection("3", [], name: "zebra readings"),
            collection("2", [], name: "Éclair club"),
            collection("1", [], name: "apple course"),
            collection("5", [], name: "Apple Course"),
            collection("4", [], name: "HIST 210"),
        ]
        XCTAssertEqual(LibraryCollectionScope.chipOrder(collections).map(\.id), ["1", "5", "2", "4", "3"])
        XCTAssertEqual(LibraryCollectionScope.chipOrder(collections.reversed()).map(\.id), ["1", "5", "2", "4", "3"], "input order never matters")
        XCTAssertEqual(LibraryCollectionScope.chipOrder([]).map(\.id), [])
    }

    /// The record a build that already shipped collections wrote: this build must read it unchanged.
    func testACollectionRecordFromThePreviousBuildDecodes() throws {
        let json = #"{"id":"course","name":"HIST 210","itemIDs":["a","b","a"],"createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-02T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ItemCollection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "HIST 210")
        let library = rows("a", "b", "c")
        XCTAssertEqual(ids(LibraryCollectionScope.rows(library, in: ItemCollectionScope(decoded))), ["a", "b"])
        XCTAssertEqual(LibraryCollectionScope.itemCount(in: decoded, among: library), 2)
    }
}
