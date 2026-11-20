import Foundation
import XCTest
@testable import SessionKit

/// #3769 (owner's decision 2026-11-19): which rows the Library lists in the Collections view and the All Items view.
final class LibraryCollectionListingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Fixtures

    private func row(
        _ id: String, title: String? = nil, added: Double? = nil, listened: Double? = nil, percent: Int? = nil,
        finished: Bool = false, marginsNew: Int = 0, mediaType: String = "text"
    ) -> LibraryItemRow {
        var row = LibraryItemRow(
            id: id, title: title ?? "Title \(id)", status: "ready", canDelete: true, hasContinuationSession: percent != nil,
            continuationProgressPercent: percent, isCompleted: finished, mediaType: mediaType,
            addedAt: added.map { base.addingTimeInterval($0) }, lastListenedAt: listened.map { base.addingTimeInterval($0) },
            storageRecencyRank: .max)
        row.sharedMargins = SharedMarginTally(total: marginsNew, new: marginsNew)
        return row
    }

    private func collection(_ id: String, _ name: String, _ items: [String] = [], created: Double = 0) -> ItemCollection {
        ItemCollection(id: id, name: name, itemIDs: items, createdAt: base.addingTimeInterval(created))
    }

    private func ids(_ listing: [LibraryCollectionEntry]) -> [String] { listing.map(\.id) }
    private func c(_ id: String) -> String { LibraryCollectionRow.rowID(collectionID: id) }

    private func list(
        _ rows: [LibraryItemRow], _ collections: [ItemCollection], imported: [LibraryFolderRecord] = [],
        query: LibraryQuery = LibraryQuery(), mode: LibraryViewMode = .collections, current: String? = nil
    ) -> [LibraryCollectionEntry] {
        LibraryCollectionListEngine.listing(rows: rows, collections: collections, imported: imported, query: query, mode: mode,
                                            currentItemID: current)
    }

    // MARK: All Items, and no collections

    func testAllItemsAndACollectionsViewWithNoCollectionAreExactlyTodaysList() {
        let rows = [row("a", added: 3, percent: 40), row("b", added: 5), row("c", added: 1, finished: true), row("d", added: 2, listened: 9)]
        for sort in LibrarySort.allCases {
            for listening in LibraryListeningStateFilter.allCases {
                for text in ["", "title"] {
                    let query = LibraryQuery(query: text, listeningState: listening, sort: sort)
                    let today = LibraryListRows.entries(visible: LibraryQueryEngine.visibleLibraryItems(rows, query: query), currentId: "d")
                    let all = list(rows, [collection("x", "Course", ["a", "b"])], query: query, mode: .allItems, current: "d")
                    XCTAssertEqual(ids(all), today.map(\.id), "\(sort) \(listening) '\(text)'")
                    XCTAssertEqual(all.map(\.isCurrent), today.map(\.isCurrent))
                    XCTAssertTrue(all.allSatisfy { $0.itemRow?.collectionNames.isEmpty == true }, "All Items adds nothing to a row")
                    XCTAssertEqual(ids(list(rows, [], query: query, current: "d")), today.map(\.id))
                }
            }
        }
    }

    func testTheViewChoiceIsSavedAndStartsOnCollections() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "view-mode-\(UUID().uuidString)"))
        XCTAssertEqual(LibraryViewMode.load(defaults: defaults), .collections)
        LibraryViewMode.allItems.save(defaults: defaults)
        XCTAssertEqual(LibraryViewMode.load(defaults: defaults), .allItems)
        defaults.set("folders", forKey: LibraryViewMode.defaultsKey)
        XCTAssertEqual(LibraryViewMode.load(defaults: defaults), .collections, "an unknown value falls back")
        XCTAssertEqual(LibraryViewMode.allCases.map(\.title), ["Collections", "All Items"])
    }

    // MARK: Browsing the Collections view

    func testEachCollectionIsOneRowOnTopAndOnlyLooseItemsAreListed() {
        let rows = [row("a", added: 1), row("b", added: 2), row("c", added: 3), row("loose", added: 4)]
        let listing = list(rows, [collection("work", "Work", ["a", "b"]), collection("fun", "Fun", ["c"])])
        XCTAssertEqual(ids(listing), [c("fun"), c("work"), "loose"], "collections first, newest add first, then loose items")
        guard case .collection(let work, _) = listing[1] else { return XCTFail("a collection row") }
        XCTAssertEqual(work.progress.detailLine, "2 items · 2 unfinished")
        XCTAssertEqual(work.playPlan?.startItemID, "a")
    }

    func testAnItemInTwoCollectionsIsInBothAndNeverLoose() {
        let rows = [row("shared", added: 1), row("a", added: 2), row("loose", added: 3)]
        let listing = list(rows, [collection("x", "X", ["shared", "a"]), collection("y", "Y", ["shared"])])
        XCTAssertEqual(Set(ids(listing)), [c("x"), c("y"), "loose"])
        let counts = listing.compactMap { entry -> Int? in
            if case .collection(let row, _) = entry { return row.progress.itemCount }
            return nil
        }
        XCTAssertEqual(counts.sorted(), [1, 2])
    }

    func testTheListeningFilterAsksEachCollectionAsAWhole() {
        let rows = [row("done1", added: 1, finished: true), row("done2", added: 2, finished: true),
                    row("part", added: 3, percent: 30), row("fresh", added: 4)]
        let cs = [collection("done", "Done", ["done1", "done2"]), collection("going", "Going", ["part"]),
                  collection("new", "New", ["fresh"]), collection("empty", "Empty")]
        func shown(_ filter: LibraryListeningStateFilter) -> Set<String> {
            Set(ids(list(rows, cs, query: LibraryQuery(listeningState: filter))))
        }
        XCTAssertEqual(shown(.unfinished), [c("going"), c("new"), c("empty")], "an empty collection stays in sight")
        XCTAssertEqual(shown(.unplayed), [c("new")])
        XCTAssertEqual(shown(.inProgress), [c("going")])
        XCTAssertEqual(shown(.completed), [c("done")])
        XCTAssertEqual(shown(.all), [c("done"), c("going"), c("new"), c("empty")])
    }

    func testAFinishedCollectionWithANewSharedMarginStaysUnderUnfinished() {
        let rows = [row("a", added: 1, finished: true, marginsNew: 1), row("b", added: 2, finished: true)]
        let listing = list(rows, [collection("x", "X", ["a", "b"])])
        XCTAssertEqual(ids(listing), [c("x")])
        guard case .collection(let x, _) = listing[0] else { return XCTFail() }
        XCTAssertEqual(x.playPlan?.label, .continue)
        XCTAssertEqual(x.playPlan?.startItemID, "a")
    }

    func testAnImportingCollectionIsListedAndSaysSo() {
        let record = LibraryFolderRecord(id: "brief", sourcePath: "/b", importedAt: base, members: [
            .init(key: "1.pdf", kind: .pdf, name: "1.pdf", itemID: "a", addedAt: base, state: .added),
            .init(key: "2.pdf", kind: .pdf, name: "2.pdf", itemID: "b", addedAt: base, state: .adding),
        ])
        let listing = list([row("a", added: 1, finished: true)], [collection("brief", "Brief", ["a"])], imported: [record],
                           query: LibraryQuery(listeningState: .unfinished))
        XCTAssertEqual(ids(listing), [c("brief")])
        guard case .collection(let brief, _) = listing[0] else { return XCTFail() }
        XCTAssertEqual(brief.progress.detailLine, "Adding 1 of 2…")
        XCTAssertTrue(brief.isImported)
        var trashed = record
        trashed.trashedAt = base
        XCTAssertEqual(ids(list([row("a", added: 1)], [collection("brief", "Brief", ["a"])], imported: [trashed])), ["a"],
                       "a collection whose import record was deleted draws nothing and leaves its items loose")
    }

    func testCollectionsSortAmongThemselvesByTheLibrarysSort() {
        let rows = [row("a", title: "A", added: 10, listened: 1), row("b", title: "B", added: 1, listened: 50, percent: 50),
                    row("c", added: 5, finished: true)]
        let cs = [collection("zed", "Zed", ["a"]), collection("alpha", "Alpha", ["b", "c"]), collection("empty", "Empty", created: 20)]
        func order(_ sort: LibrarySort) -> [String] { ids(list(rows, cs, query: LibraryQuery(listeningState: .all, sort: sort))) }
        XCTAssertEqual(order(.recentlyAdded), [c("empty"), c("zed"), c("alpha")], "an empty collection sorts by when it was made")
        XCTAssertEqual(order(.title), [c("alpha"), c("empty"), c("zed")])
        XCTAssertEqual(order(.recentlyListened), [c("alpha"), c("zed"), c("empty")])
        XCTAssertEqual(order(.progress), [c("alpha"), c("empty"), c("zed")], "half finished, then none")
    }

    func testTheContinueItemInsideACollectionMarksThatCollectionCurrentAndDrawsItFirst() {
        let rows = [row("a", added: 1, percent: 20), row("loose", added: 9)]
        let listing = list(rows, [collection("x", "X", ["a"]), collection("y", "Y", [], created: 50)], current: "a")
        XCTAssertEqual(ids(listing), [c("x"), c("y"), "loose"])
        XCTAssertEqual(listing.map(\.isCurrent), [true, false, false])
        let looseCurrent = list(rows, [collection("x", "X", ["a"])], current: "loose")
        XCTAssertEqual(ids(looseCurrent), ["loose", c("x")])
        XCTAssertEqual(looseCurrent.map(\.isCurrent), [true, false])
    }

    // MARK: Searching and filtering the Collections view

    func testASearchListsMatchingItemsOnTheirOwnWithTheirCollectionsAndMatchingCollectionsFirst() {
        let rows = [row("a", title: "Brief one", added: 1), row("b", title: "Other", added: 2), row("c", title: "Brief two", added: 3)]
        let cs = [collection("daily", "Daily Brief", ["a", "b"]), collection("misc", "Misc", ["a"])]
        let listing = list(rows, cs, query: LibraryQuery(query: "brief"))
        XCTAssertEqual(ids(listing), [c("daily"), "c", "a"])
        XCTAssertEqual(listing[2].itemRow?.collectionNames, ["Daily Brief", "Misc"])
        XCTAssertEqual(listing[1].itemRow?.collectionNames, [])
        XCTAssertEqual(ids(list(rows, cs, query: LibraryQuery(query: "  BRÏEF "))).first, c("daily"), "case, accents and spaces")
    }

    func testAnyOtherFilterListsItemsOnlyWithNoCollectionRows() {
        let rows = [row("a", added: 1), row("b", added: 2, mediaType: "podcast")]
        let listing = list(rows, [collection("x", "X", ["a", "b"])], query: LibraryQuery(contentType: .text))
        XCTAssertEqual(ids(listing), ["a"])
        XCTAssertEqual(listing[0].itemRow?.collectionNames, ["X"])
        let searchAndFilter = list(rows, [collection("x", "X", ["a", "b"])], query: LibraryQuery(query: "x", contentType: .text))
        XCTAssertFalse(ids(searchAndFilter).contains(c("x")), "a collection's name only matches a plain search")
    }

    func testTheDetailLineNamesTheCollections() {
        XCTAssertEqual(LibraryCollectionListEngine.detailLine("12 min", collectionNames: []), "12 min")
        XCTAssertEqual(LibraryCollectionListEngine.detailLine("12 min", collectionNames: ["Brief"]), "12 min · in Brief")
        XCTAssertEqual(LibraryCollectionListEngine.detailLine("12 min", collectionNames: ["A", "B"]), "12 min · in A and 1 other")
        XCTAssertEqual(LibraryCollectionListEngine.detailLine("", collectionNames: ["A", "B", "C"]), "in A and 2 others")
    }

    // MARK: Caught up and added-item visibility

    func testCaughtUpCountsACollectionAsOneRow() {
        let finished = [row("a", added: 1, finished: true), row("b", added: 2, finished: true)]
        XCTAssertTrue(LibraryCollectionListEngine.isCaughtUp(rows: finished, collections: [collection("x", "X", ["a"])],
                                                             query: LibraryQuery(), mode: .collections))
        XCTAssertFalse(LibraryCollectionListEngine.isCaughtUp(rows: finished, collections: [collection("x", "X", ["a"]), collection("e", "E")],
                                                              query: LibraryQuery(), mode: .collections), "an empty collection is not done")
        XCTAssertFalse(LibraryCollectionListEngine.isCaughtUp(rows: finished + [row("c", added: 3)], collections: [collection("x", "X", ["c"])],
                                                              query: LibraryQuery(), mode: .collections))
        XCTAssertEqual(LibraryCollectionListEngine.isCaughtUp(rows: finished, collections: [collection("e", "E")], query: LibraryQuery(), mode: .allItems),
                       LibraryQueryEngine.libraryIsCaughtUp(finished, query: LibraryQuery()))
    }

    func testAnAddedItemInsideACollectionSaysWhereItWent() {
        let rows = [row("a", added: 1)]
        let cs = [collection("x", "X", ["a"])]
        XCTAssertEqual(LibraryCollectionListEngine.addedItemVisibility(itemId: "a", rows: rows, collections: cs, query: LibraryQuery(), mode: .collections),
                       "hidden:in_collection")
        XCTAssertEqual(LibraryCollectionListEngine.addedItemVisibility(itemId: "a", rows: rows, collections: cs, query: LibraryQuery(), mode: .allItems),
                       "visible:row_1")
        XCTAssertEqual(LibraryCollectionListEngine.addedItemVisibility(itemId: "zz", rows: rows, collections: cs, query: LibraryQuery(), mode: .collections),
                       "hidden:no_row")
    }

    func testPickerRowsAreAlphabeticalWithTheirCounts() {
        let rows = [row("a"), row("b")]
        let pickers = LibraryCollectionListEngine.collectionRows(rows: rows, collections: [collection("2", "beta", ["a", "b", "gone"]), collection("1", "Alpha")])
        XCTAssertEqual(pickers.map(\.name), ["Alpha", "beta"])
        XCTAssertEqual(pickers.map(\.progress.itemCount), [0, 2], "an item that is not a row is not counted")
        XCTAssertNil(pickers[0].playPlan)
    }
}
