import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3769: which rows the Library list shows once some items belong to Library folders, and in what order.
final class LibraryFolderQueryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Fixtures

    private func row(
        _ id: String, title: String? = nil, added: Double? = nil, listened: Double? = nil, percent: Int? = nil,
        finished: Bool = false, rank: Int = .max, marginsNew: Int = 0, mediaType: String = "text"
    ) -> LibraryItemRow {
        var row = LibraryItemRow(
            id: id, title: title ?? "Title \(id)", status: "ready", canDelete: true, hasContinuationSession: percent != nil,
            continuationProgressPercent: percent, isCompleted: finished, mediaType: mediaType,
            addedAt: added.map { base.addingTimeInterval($0) }, lastListenedAt: listened.map { base.addingTimeInterval($0) },
            storageRecencyRank: rank)
        row.sharedMargins = SharedMarginTally(total: marginsNew, new: marginsNew)
        return row
    }

    private func collection(_ id: String, _ name: String, items: [String] = []) -> ItemCollection {
        ItemCollection(id: id, name: name, itemIDs: items, createdAt: base)
    }

    private func folder(
        _ id: String, items: [String], imported: Double = 0, trashed: Bool = false,
        extra: [LibraryFolderRecord.Member] = [], notAdded: Int = 0
    ) -> LibraryFolderRecord {
        LibraryFolderRecord(
            id: id, sourcePath: "/x/\(id)", importedAt: base.addingTimeInterval(imported),
            trashedAt: trashed ? base : nil,
            notAdded: (0..<notAdded).map { .init(key: "n\($0)", name: "n\($0)", reason: "r") },
            members: items.enumerated().map { index, itemID in
                LibraryFolderRecord.Member(key: "\(index + 1).pdf", kind: .pdf, name: "\(index + 1).pdf", itemID: itemID,
                                           addedAt: base, state: .added)
            } + extra)
    }

    private func ids(_ listing: [LibraryListing]) -> [String] { listing.map(\.id) }

    private func list(
        _ rows: [LibraryItemRow], collections: [ItemCollection], folders: [LibraryFolderRecord],
        query: LibraryQuery = LibraryQuery(), current: String? = nil
    ) -> [LibraryListing] {
        LibraryFolderListEngine.listing(rows: rows, collections: collections, folders: folders, query: query, currentItemID: current)
    }

    // MARK: Nothing changes without a folder

    func testWithNoFolderTheListIsExactlyTodaysList() {
        let rows = [row("a", added: 3, percent: 40), row("b", added: 5), row("c", added: 1, finished: true), row("d", added: 2, listened: 9)]
        for sort in LibrarySort.allCases {
            for listening in LibraryListeningStateFilter.allCases {
                for text in ["", "title"] {
                    let query = LibraryQuery(query: text, listeningState: listening, sort: sort)
                    let today = LibraryListRows.entries(visible: LibraryQueryEngine.visibleLibraryItems(rows, query: query), currentId: "d")
                    let now = list(rows, collections: [collection("plain", "Course", items: ["a"])], folders: [], query: query, current: "d")
                    XCTAssertEqual(ids(now), today.map(\.id), "\(sort) \(listening) '\(text)'")
                    XCTAssertEqual(now.map(\.isCurrent), today.map(\.isCurrent))
                }
            }
        }
    }

    func testADeletedFolderAndAnOrphanDrawNothingAndLeaveItsItemsFlat() {
        let rows = [row("a", added: 1), row("b", added: 2)]
        let cs = [collection("gone", "Deleted brief", items: ["a", "b"])]
        XCTAssertEqual(ids(list(rows, collections: cs, folders: [folder("gone", items: ["a", "b"], trashed: true)])), ["b", "a"])
        XCTAssertEqual(ids(list(rows, collections: [], folders: [folder("orphan", items: ["a", "b"])])), ["b", "a"],
                       "no collection behind the record")
    }

    // MARK: Browsing

    func testWhileBrowsingOneRowStandsForTheFoldersItems() {
        let rows = (1...24).map { row("p\($0)", added: Double($0)) } + [row("loose", added: 0)]
        let listing = list(rows, collections: [collection("f", "Daily Brief")], folders: [folder("f", items: (1...24).map { "p\($0)" })])
        XCTAssertEqual(ids(listing), ["folder:f", "loose"], "nothing scattered through the Library")
        guard case .folder(let folderRow, let isCurrent) = listing[0] else { return XCTFail("a folder row first") }
        XCTAssertFalse(isCurrent)
        XCTAssertEqual(folderRow.name, "Daily Brief")
        XCTAssertEqual(folderRow.progress.detailLine, "24 items · 24 unfinished")
        XCTAssertEqual(folderRow.playPlan?.startItemID, "p1")
    }

    func testItemsTheListenerRemovedFromTheFolderAreListedOnTheirOwn() {
        let rows = [row("a", added: 1), row("b", added: 2)]
        var record = folder("f", items: ["a", "b"])
        record.members[1].state = .removed
        XCTAssertEqual(ids(list(rows, collections: [collection("f", "F")], folders: [record])).sorted(), ["b", "folder:f"])
    }

    func testAMemberInRecentlyDeletedIsInNoRowAndNoCount() {
        let rows = [row("a", added: 1)] // "b" is trashed, so it is not a row at all
        let listing = list(rows, collections: [collection("f", "F")], folders: [folder("f", items: ["a", "b"])])
        guard case .folder(let folderRow, _) = listing[0] else { return XCTFail("a folder row") }
        XCTAssertEqual(folderRow.progress.itemCount, 1)
        XCTAssertEqual(folderRow.progress.detailLine, "1 item · 1 unfinished")
    }

    // MARK: The Listening filter applies to the folder row

    func testEachListeningFilterAsksTheWholeFolder() {
        let rows = [row("a", finished: true), row("b", percent: 30), row("c")]
        let cs = [collection("f", "F")]
        let mixed = [folder("f", items: ["a", "b", "c"])]
        func shown(_ filter: LibraryListeningStateFilter, _ r: [LibraryItemRow] = rows, _ f: [LibraryFolderRecord]? = nil) -> Bool {
            ids(list(r, collections: cs, folders: f ?? mixed, query: LibraryQuery(listeningState: filter))).contains("folder:f")
        }
        XCTAssertTrue(shown(.unfinished))
        XCTAssertTrue(shown(.unplayed), "item c is not started")
        XCTAssertTrue(shown(.inProgress), "item b is part way")
        XCTAssertFalse(shown(.completed), "not every item is finished")
        XCTAssertTrue(shown(.all))

        let allDone = [row("a", finished: true), row("b", finished: true)]
        let done = [folder("f", items: ["a", "b"])]
        XCTAssertFalse(shown(.unfinished, allDone, done))
        XCTAssertFalse(shown(.unplayed, allDone, done))
        XCTAssertFalse(shown(.inProgress, allDone, done))
        XCTAssertTrue(shown(.completed, allDone, done))
        XCTAssertTrue(shown(.all, allDone, done))
    }

    func testNewSharedMarginsOnAFinishedMemberKeepTheFolderUnderUnfinished() {
        let rows = [row("a", finished: true, marginsNew: 1), row("b", finished: true)]
        let cs = [collection("f", "F")]
        let fs = [folder("f", items: ["a", "b"])]
        XCTAssertTrue(ids(list(rows, collections: cs, folders: fs)).contains("folder:f"), "the shared line has something to say")
        XCTAssertFalse(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(listeningState: .unplayed))).contains("folder:f"),
                       "Unplayed means the listener's own listening")
        XCTAssertTrue(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(listeningState: .completed))).contains("folder:f"))
    }

    func testAnEmptyFolderShowsUnderAllOnly() {
        let cs = [collection("f", "F")]
        let fs = [folder("f", items: [])]
        for filter in LibraryListeningStateFilter.allCases {
            XCTAssertEqual(ids(list([], collections: cs, folders: fs, query: LibraryQuery(listeningState: filter))).contains("folder:f"),
                           filter == .all, "\(filter)")
        }
    }

    func testAFolderStillImportingAndAFolderWhoseFilesAllFailedAreVisibleUnderTheDefaultFilter() {
        let cs = [collection("f", "F")]
        let importing = LibraryFolderRecord(id: "f", sourcePath: "/x", importedAt: base, members: [
            .init(key: "1.pdf", kind: .pdf, name: "1.pdf", itemID: "i1", addedAt: base, state: .adding)])
        XCTAssertTrue(ids(list([], collections: cs, folders: [importing])).contains("folder:f"), "the row appears at once")
        XCTAssertTrue(ids(list([], collections: cs, folders: [importing], query: LibraryQuery(listeningState: .unplayed))).contains("folder:f"))
        XCTAssertFalse(ids(list([], collections: cs, folders: [importing], query: LibraryQuery(listeningState: .completed))).contains("folder:f"))

        let failed = LibraryFolderRecord(id: "f", sourcePath: "/x", importedAt: base, members: [
            .init(key: "1.pdf", kind: .pdf, name: "1.pdf", addedAt: base, state: .failed, reason: "Couldn't be opened")])
        let listing = list([], collections: cs, folders: [failed])
        XCTAssertEqual(ids(listing), ["folder:f"], "so the listener can see what failed")
        guard case .folder(let failedRow, _) = listing[0] else { return XCTFail("a folder row") }
        XCTAssertEqual(failedRow.progress.detailLine, "1 not added")
    }

    // MARK: Searching and other filters

    func testSearchingListsMatchingItemsOnTheirOwnWithTheFoldersName() {
        let rows = [row("a", title: "Quarterly report", added: 1), row("b", title: "Weather", added: 2), row("c", title: "Quarterly notes", added: 3)]
        let cs = [collection("f", "Daily Brief")]
        let fs = [folder("f", items: ["a", "b"])]
        let listing = list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "quarterly"))
        XCTAssertEqual(ids(listing), ["c", "a"])
        guard case .item(let inFolder, _) = listing[1], case .item(let loose, _) = listing[0] else { return XCTFail("items") }
        XCTAssertEqual(inFolder.folderName, "Daily Brief")
        XCTAssertNil(loose.folderName)
        XCTAssertEqual(LibraryFolderListEngine.detailLine("12 min", folderName: inFolder.folderName), "12 min · in Daily Brief")
        XCTAssertEqual(LibraryFolderListEngine.detailLine("12 min", folderName: nil), "12 min")
        XCTAssertEqual(LibraryFolderListEngine.detailLine("", folderName: "Daily Brief"), "in Daily Brief")
    }

    func testSearchingAlsoListsAFolderWhoseNameMatches() {
        let rows = [row("a", title: "Weather", added: 1), row("z", title: "Unrelated", added: 2)]
        let cs = [collection("f", "Daily Brief")]
        let fs = [folder("f", items: ["a"])]
        XCTAssertEqual(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "brief"))), ["folder:f"])
        XCTAssertEqual(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "DAILY"))), ["folder:f"], "case")
        XCTAssertEqual(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "weather"))), ["a"], "an item, not its folder")
        XCTAssertEqual(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "nothing"))), [])
    }

    func testAnyOtherFilterListsItemsOnTheirOwnAndNoFolderRows() {
        let rows = [row("a", added: 1, mediaType: "pdf"), row("b", added: 2, mediaType: "pdf"), row("c", added: 3)]
        let cs = [collection("f", "Daily Brief")]
        let fs = [folder("f", items: ["a", "b"])]
        let listing = list(rows, collections: cs, folders: fs, query: LibraryQuery(contentType: .pdf))
        XCTAssertEqual(ids(listing), ["b", "a"])
        XCTAssertEqual(listing.compactMap { if case .item(let r, _) = $0 { r.folderName } else { nil } }, ["Daily Brief", "Daily Brief"])
        XCTAssertFalse(ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(query: "brief", contentType: .pdf))).contains("folder:f"),
                       "search text with another filter set shows no folder row")
    }

    // MARK: Sort

    func testFoldersSortAmongItemsByTheSameRules() {
        let rows = [
            row("a", title: "Alpha", added: 10, listened: 5, percent: 10), row("b", title: "Bravo", added: 30, listened: 50, percent: 90),
            row("x", title: "Zulu", added: 20, listened: 80, finished: true), row("y", title: "Yankee", added: 5),
            row("loose", title: "Mike", added: 25, listened: 20, percent: 50),
        ]
        let cs = [collection("f", "Brief")]
        let fs = [folder("f", items: ["a", "b", "x", "y"])]
        func order(_ sort: LibrarySort) -> [String] {
            ids(list(rows, collections: cs, folders: fs, query: LibraryQuery(listeningState: .all, sort: sort)))
        }
        XCTAssertEqual(order(.recentlyAdded), ["folder:f", "loose"], "the folder takes the newest add among its items (30)")
        XCTAssertEqual(order(.published), ["folder:f", "loose"], "the same as Recently Added")
        XCTAssertEqual(order(.recentlyListened), ["folder:f", "loose"], "the newest listening among its items (80)")
        XCTAssertEqual(order(.title), ["folder:f", "loose"], "Brief before Mike")
        XCTAssertEqual(order(.progress), ["loose", "folder:f"], "1 of 4 finished is 25%; the loose item is at 50%")
        // And with the dates turned round, the folder gives way.
        let old = [row("a", added: 1), row("b", added: 2), row("loose", added: 99)]
        XCTAssertEqual(ids(list(old, collections: cs, folders: [folder("f", items: ["a", "b"])])), ["loose", "folder:f"])
    }

    func testAFolderThatIsStillWaitingForItsFirstItemSortsAsNew() {
        let rows = [row("loose", added: 5)]
        let importing = LibraryFolderRecord(id: "f", sourcePath: "/x", importedAt: base.addingTimeInterval(100), members: [
            .init(key: "1.pdf", kind: .pdf, name: "1.pdf", itemID: "i1", addedAt: base, state: .adding)])
        XCTAssertEqual(ids(list(rows, collections: [collection("f", "F")], folders: [importing])), ["folder:f", "loose"])
    }

    // MARK: Continue

    func testContinueInsideAFolderMarksTheFolderRowCurrentAndDrawsItFirst() {
        let rows = [row("a", added: 1, percent: 20), row("b", added: 2), row("loose", added: 99)]
        let cs = [collection("f", "F")]
        let listing = list(rows, collections: cs, folders: [folder("f", items: ["a", "b"])], current: "a")
        XCTAssertEqual(ids(listing), ["folder:f", "loose"])
        XCTAssertEqual(listing.map(\.isCurrent), [true, false])
        let other = list(rows, collections: cs, folders: [folder("f", items: ["a", "b"])], current: "loose")
        XCTAssertEqual(ids(other), ["loose", "folder:f"])
        XCTAssertEqual(other.map(\.isCurrent), [true, false])
    }

    func testContinueIsTheItemItselfWhenTheListShowsItemsOnTheirOwn() {
        let rows = [row("a", title: "Report one", added: 1, percent: 20), row("b", title: "Report two", added: 2)]
        let listing = list(rows, collections: [collection("f", "F")], folders: [folder("f", items: ["a", "b"])],
                           query: LibraryQuery(query: "report"), current: "a")
        XCTAssertEqual(ids(listing), ["a", "b"])
        XCTAssertEqual(listing.map(\.isCurrent), [true, false])
    }

    func testContinueInAFolderThatTheFilterHidesMarksNothing() {
        let rows = [row("a", added: 1, finished: true), row("loose", added: 2)]
        let listing = list(rows, collections: [collection("f", "F")], folders: [folder("f", items: ["a"])], current: "a")
        XCTAssertEqual(ids(listing), ["loose"])
        XCTAssertEqual(listing.map(\.isCurrent), [false])
    }

    // MARK: Added, caught up

    func testAnItemInsideAFolderIsHiddenInFolderWhileBrowsing() {
        let rows = [row("a", added: 1), row("loose", added: 2)]
        let cs = [collection("f", "F")]
        let fs = [folder("f", items: ["a"])]
        func visibility(_ id: String, _ query: LibraryQuery = LibraryQuery()) -> String {
            LibraryFolderListEngine.addedItemVisibility(itemId: id, rows: rows, collections: cs, folders: fs, query: query)
        }
        XCTAssertEqual(visibility("a"), "hidden:in_folder")
        XCTAssertEqual(visibility("loose"), "visible:row_1")
        XCTAssertEqual(visibility("missing"), "hidden:no_row")
        XCTAssertEqual(visibility("a", LibraryQuery(query: "Title a")), "visible:row_1", "searching lists it on its own")
    }

    func testCaughtUpCountsAFolderAsOneRow() {
        let cs = [collection("f", "F")]
        let finishedRows = [row("a", finished: true), row("b", finished: true), row("loose", finished: true)]
        XCTAssertTrue(LibraryFolderListEngine.isCaughtUp(rows: finishedRows, collections: cs, folders: [folder("f", items: ["a", "b"])], query: LibraryQuery()))
        let oneOpen = [row("a", finished: true), row("b"), row("loose", finished: true)]
        XCTAssertFalse(LibraryFolderListEngine.isCaughtUp(rows: oneOpen, collections: cs, folders: [folder("f", items: ["a", "b"])], query: LibraryQuery()))
        XCTAssertFalse(LibraryFolderListEngine.isCaughtUp(rows: finishedRows, collections: cs, folders: [folder("f", items: ["a", "b"])],
                                                          query: LibraryQuery(query: "x")), "a search is not caught up")
        XCTAssertFalse(LibraryFolderListEngine.isCaughtUp(rows: [], collections: [], folders: [], query: LibraryQuery()), "an empty Library")
    }

    // MARK: The snapshot

    func testTheSnapshotCarriesCollectionsAndFolderRecordsWhileAWriterHoldsTheStore() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "folder-query-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        for index in 1...3 {
            try store.saveItem(Item(id: "i\(index)", title: "Item \(index)", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        try store.saveItemCollection(ItemCollection(id: "f", name: "Daily Brief", itemIDs: ["i1", "i2"], createdAt: base))
        try store.saveLibraryFolder(folder("f", items: ["i1", "i2"]))

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK, "another writer holds the store")
        defer { sqlite3_exec(writer, "COMMIT", nil, nil, nil); sqlite3_close(writer) }

        let started = Date()
        let snapshot = try LibraryReadSnapshot.read(store: store)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the Library read does not wait for the writer")
        XCTAssertEqual(snapshot.collections?.map(\.id), ["f"])
        XCTAssertEqual(snapshot.libraryFolders.map(\.id), ["f"])

        let rows = LibraryRowBuilder.rows(from: snapshot, context: StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true))
        let listing = LibraryFolderListEngine.listing(rows: rows, collections: snapshot.collections ?? [], folders: snapshot.libraryFolders,
                                                      query: LibraryQuery(), currentItemID: nil)
        XCTAssertEqual(Set(ids(listing)), ["folder:f", "i3"], "the folder's items are never listed flat in the first frame")
    }

    func testASnapshotBuiltTheOldWayHasNoFolders() {
        let snapshot = LibraryReadSnapshot(items: [Item](), sessions: [], manifests: [], jobs: [], downloads: [])
        XCTAssertNil(snapshot.collections, "nothing was read")
        XCTAssertTrue(snapshot.libraryFolders.isEmpty)
    }
}
