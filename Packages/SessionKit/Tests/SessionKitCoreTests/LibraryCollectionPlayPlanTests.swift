import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3769: where a collection's ▶ starts, what it queues behind it, and the words the row and screen use. Rows come from a real
/// temporary store through `LibraryRowBuilder`, so "finished" is whatever `ItemFinishedRule` says.
final class LibraryCollectionPlayPlanTests: XCTestCase {
    private var store: SQLiteSessionStore!
    private let context = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true)
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        store = try SQLiteSessionStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-plan-\(UUID().uuidString).sqlite").path)
    }

    override func tearDownWithError() throws { store = nil }

    // MARK: Fixtures

    private enum Listening {
        case none
        case percent(Int, at: Double)          // part way, or "heard" at 99
        case finished(at: Double)              // played to the end
        case markedComplete
        case finishedThenAddedAgain(finishedAt: Double, addedAgainAt: Double)
    }

    /// Saves one text item per entry (ids `i1`, `i2`, …) with the listening each describes.
    private func save(_ listening: [Listening]) throws {
        for (index, state) in listening.enumerated() {
            let id = "i\(index + 1)"
            var item = Item(id: id, title: "Item \(index + 1)", mediaType: "text", text: "Body \(index + 1)", externalReference: nil, status: "ready")
            func session(_ percent: Int, at seconds: Double, finished: Bool) -> Session {
                let date = base.addingTimeInterval(seconds)
                return Session(id: "s\(id)", itemId: id, createdAt: date, updatedAt: date, completedAt: finished ? date : nil,
                               status: finished ? "finished" : "in_progress", phase: finished ? .finished : .itemPlayback,
                               currentTargetType: .itemTextTTS, currentTargetId: id, position: Position(charOffset: 3),
                               completionPercent: percent, playbackRate: 1)
            }
            switch state {
            case .none: break
            case .percent(let percent, let at): try store.saveSession(session(percent, at: at, finished: false))
            case .finished(let at): try store.saveSession(session(100, at: at, finished: true))
            case .markedComplete: item.sourceCompletedAt = base
            case .finishedThenAddedAgain(let finishedAt, let addedAgainAt):
                try store.saveSession(session(100, at: finishedAt, finished: true))
                item.addedAgainAt = base.addingTimeInterval(addedAgainAt)
            }
            try store.saveItem(item)
        }
    }

    private func rows() throws -> [String: LibraryItemRow] {
        let built = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: context)
        return Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
    }

    private func member(_ number: Int, state: LibraryFolderRecord.MemberState = .added, id: String? = nil) -> LibraryFolderRecord.Member {
        LibraryFolderRecord.Member(key: "\(number).pdf", kind: .pdf, name: "\(number).pdf", itemID: id ?? "i\(number)",
                                   addedAt: base, state: state)
    }

    private func folder(_ members: [LibraryFolderRecord.Member], notAdded: Int = 0) -> LibraryFolderRecord {
        LibraryFolderRecord(id: "f", sourcePath: "/x", importedAt: base,
                            notAdded: (0..<notAdded).map { .init(key: "n\($0)", name: "n\($0)", reason: "r") }, members: members)
    }

    private func collection(_ ids: [String]) -> ItemCollection {
        ItemCollection(id: "f", name: "Brief", itemIDs: ids, createdAt: base)
    }

    private func progress(_ listening: [Listening], tweak: (inout [String: LibraryItemRow]) -> Void = { _ in }) throws -> LibraryCollectionProgress {
        try save(listening)
        var all = try rows()
        tweak(&all)
        return LibraryCollectionProgress(collection: collection((1...listening.count).map { "i\($0)" }), rows: all)
    }

    private func resume(_ listening: [Listening], tweak: (inout [String: LibraryItemRow]) -> Void = { _ in }) throws -> LibraryCollectionPlayPlan {
        try XCTUnwrap(LibraryCollectionPlayPlan.resume(try progress(listening, tweak: tweak)))
    }

    // MARK: The play rule

    func testACollectionNobodyHasListenedToStartsAtItemOneAndQueuesTheRest() throws {
        let plan = try resume([.none, .none, .none])
        XCTAssertEqual(plan.label, .start)
        XCTAssertEqual(plan.startItemID, "i1")
        XCTAssertEqual(plan.queuedItemIDs, ["i2", "i3"])
    }

    func testItResumesTheUnfinishedItemListenedToMostRecentlyNotTheFirst() throws {
        // After "Play from here" on item 3, Continue carries on at item 3 rather than jumping back to item 1.
        let plan = try resume([.percent(40, at: 10), .finished(at: 20), .percent(10, at: 30), .none])
        XCTAssertEqual(plan.label, .continue)
        XCTAssertEqual(plan.startItemID, "i3")
        XCTAssertEqual(plan.queuedItemIDs, ["i4"], "only the unfinished items after it")
    }

    func testTwoItemsPartWayResumeTheNewerOne() throws {
        let plan = try resume([.percent(40, at: 50), .percent(10, at: 30), .none])
        XCTAssertEqual(plan.startItemID, "i1")
        XCTAssertEqual(plan.queuedItemIDs, ["i2", "i3"])
    }

    func testWhenTheOnlyListeningIsOnFinishedItemsItStartsAtTheFirstUnfinishedOne() throws {
        let plan = try resume([.finished(at: 10), .none, .none])
        XCTAssertEqual(plan.label, .continue, "something in the collection was heard")
        XCTAssertEqual(plan.startItemID, "i2")
        XCTAssertEqual(plan.queuedItemIDs, ["i3"])
    }

    func testEachFinishedCaseOnItsOwn() throws {
        try save([.percent(99, at: 10), .finished(at: 20), .markedComplete,
                  .finishedThenAddedAgain(finishedAt: 30, addedAgainAt: 100), .percent(98, at: 40), .none])
        let all = try rows()
        let state = { (id: String) in LibraryCollectionProgress.state(of: all[id]!) }
        XCTAssertEqual(state("i1"), .finished, "99% counts as heard")
        XCTAssertEqual(state("i2"), .finished, "played to the end")
        XCTAssertEqual(state("i3"), .finished, "marked complete by hand")
        XCTAssertNotEqual(state("i4"), .finished, "added again after finishing starts over")
        XCTAssertEqual(state("i5"), .partWay(percent: 98))
        XCTAssertEqual(state("i6"), .notStarted)
    }

    func testFinishedItemsAreSkippedByThePlanInEveryFinishedWay() throws {
        let plan = try resume([.percent(99, at: 10), .finished(at: 20), .markedComplete, .none, .none])
        XCTAssertEqual(plan.startItemID, "i4")
        XCTAssertEqual(plan.queuedItemIDs, ["i5"])
        XCTAssertEqual(plan.label, .continue)
    }

    func testAllFinishedPlaysAgainFromItemOneAndQueuesEveryOther() throws {
        let plan = try resume([.finished(at: 10), .finished(at: 20), .markedComplete])
        XCTAssertEqual(plan.label, .playAgain)
        XCTAssertEqual(plan.startItemID, "i1")
        XCTAssertEqual(plan.queuedItemIDs, ["i2", "i3"])
    }

    func testAllFinishedWithNothingHeardIsStillPlayAgain() throws {
        // Every item marked complete by hand: nothing was listened to, but "Start" would be wrong for finished items.
        XCTAssertEqual(try resume([.markedComplete, .markedComplete]).label, .playAgain)
    }

    func testAllFinishedWithNewSharedMarginsContinuesAtThatItemAndQueuesNothing() throws {
        let plan = try resume([.finished(at: 10), .finished(at: 20), .finished(at: 30)]) { rows in
            rows["i2"]?.sharedMargins = SharedMarginTally(total: 2, new: 1)
        }
        XCTAssertEqual(plan.label, .continue)
        XCTAssertEqual(plan.startItemID, "i2")
        XCTAssertEqual(plan.queuedItemIDs, [], "the finished items after it are not lined up")
    }

    func testNewSharedMarginsDoNotChangeACollectionThatHasUnfinishedItems() throws {
        let plan = try resume([.finished(at: 10), .none]) { rows in
            rows["i1"]?.sharedMargins = SharedMarginTally(total: 1, new: 1)
        }
        XCTAssertEqual(plan.startItemID, "i2")
    }

    func testAnEmptyCollectionHasNoPlanAndNoLiveItemsMeansNone() throws {
        XCTAssertNil(LibraryCollectionPlayPlan.resume(LibraryCollectionProgress(collection: collection([]), rows: [:])))
        let arriving = LibraryCollectionProgress(collection: collection([]), imported: folder([member(1, state: .adding)]), rows: [:])
        XCTAssertNil(LibraryCollectionPlayPlan.resume(arriving), "disabled until the first item is in")
        XCTAssertFalse(arriving.canPlay)
    }

    func testPlayFromHereOnTheLastItemQueuesNothing() throws {
        let progress = try self.progress([.none, .none, .none])
        let plan = try XCTUnwrap(LibraryCollectionPlayPlan.playFrom(itemID: "i3", progress))
        XCTAssertEqual(plan.startItemID, "i3")
        XCTAssertEqual(plan.queuedItemIDs, [])
        XCTAssertEqual(plan.banner(name: "Brief"), "Playing “Brief”.")
    }

    func testPlayFromHereQueuesTheUnfinishedItemsAfterIt() throws {
        let progress = try self.progress([.none, .none, .finished(at: 10), .none, .percent(5, at: 20)])
        let plan = try XCTUnwrap(LibraryCollectionPlayPlan.playFrom(itemID: "i2", progress))
        XCTAssertEqual(plan.queuedItemIDs, ["i4", "i5"])
        XCTAssertEqual(plan.banner(name: "Brief"), "Playing “Brief” · 2 more in the queue.")
        XCTAssertEqual(try XCTUnwrap(LibraryCollectionPlayPlan.playFrom(itemID: "i4", progress)).banner(name: "Brief"),
                       "Playing “Brief” · 1 more in the queue.")
        XCTAssertNil(LibraryCollectionPlayPlan.playFrom(itemID: "elsewhere", progress), "not an item of this collection")
    }

    func testPlayFromHereWhenEverythingIsFinishedLinesUpTheRest() throws {
        let progress = try self.progress([.finished(at: 10), .finished(at: 20), .finished(at: 30)])
        let plan = try XCTUnwrap(LibraryCollectionPlayPlan.playFrom(itemID: "i2", progress))
        XCTAssertEqual(plan.queuedItemIDs, ["i3"])
        XCTAssertEqual(plan.label, .playAgain)
    }

    func testTheLabelsSayWhatVoiceOverShouldRead() {
        XCTAssertEqual(LibraryCollectionPlayPlan.Label.start.accessibilityLabel(name: "Daily Brief"), "Play all of Daily Brief")
        XCTAssertEqual(LibraryCollectionPlayPlan.Label.start.rawValue, "Play All")
        XCTAssertEqual(LibraryCollectionPlayPlan.Label.continue.accessibilityLabel(name: "Daily Brief"), "Continue Daily Brief")
        XCTAssertEqual(LibraryCollectionPlayPlan.Label.playAgain.accessibilityLabel(name: "Daily Brief"), "Play Daily Brief again")
        XCTAssertEqual(LibraryCollectionPlayPlan.Label.playAgain.rawValue, "Play Again")
    }

    // MARK: Which items are live

    func testDeletedAndUnsavedItemsAreNotLiveAndRestoringBringsThemBackInPlace() throws {
        try save([.none, .none, .none])
        try store.moveItemToTrash(id: "i2")
        let members = collection(["i1", "i2", "i3", "never-saved"])
        let progress = LibraryCollectionProgress(collection: members, rows: try rows())
        XCTAssertEqual(progress.entries.map(\.itemID), ["i1", "i3"], "a deleted item is in no row and no count")
        XCTAssertEqual(progress.entries.map(\.number), [1, 2], "numbers count live items only")
        XCTAssertEqual(progress.entries[1].accessibilityLabel(of: 2), "2 of 2, Not started, Item 3")
        try store.restoreItem(id: "i2")
        XCTAssertEqual(LibraryCollectionProgress(collection: members, rows: try rows()).entries.map(\.itemID), ["i1", "i2", "i3"])
    }

    func testAnImportRecordAddsWhatIsStillArrivingAndWhatFailed() throws {
        try save([.none, .none, .none, .none, .none])
        let members = [member(1), member(2, state: .removed), member(3), member(4, state: .failed), member(5, state: .adding)]
        let progress = LibraryCollectionProgress(collection: collection(["i1", "i3"]), imported: folder(members, notAdded: 1), rows: try rows())
        XCTAssertEqual(progress.entries.map(\.itemID), ["i1", "i3"], "the collection's own list says who is in it")
        XCTAssertEqual(progress.addingCount, 1)
        XCTAssertEqual(progress.notAddedCount, 2, "the failed member and the walk's named file")
        XCTAssertEqual(progress.detailLine, "Adding 3 of 4…")
        var trashed = folder(members)
        trashed.trashedAt = base
        XCTAssertEqual(LibraryCollectionProgress(collection: collection(["i1"]), imported: trashed, rows: try rows()).addingCount, 0,
                       "a deleted record is ignored")
    }

    func testTheSameItemCountsInEveryCollectionItIsIn() throws {
        try save([.none, .finished(at: 10)])
        let all = try rows()
        let a = LibraryCollectionProgress(collection: ItemCollection(id: "a", name: "A", itemIDs: ["i1", "i2"], createdAt: base), rows: all)
        let b = LibraryCollectionProgress(collection: ItemCollection(id: "b", name: "B", itemIDs: ["i2", "i1"], createdAt: base), rows: all)
        XCTAssertEqual(a.itemIDs, ["i1", "i2"])
        XCTAssertEqual(b.itemIDs, ["i2", "i1"], "each collection keeps its own order")
        XCTAssertEqual(LibraryCollectionPlayPlan.resume(b)?.startItemID, "i1")
    }

    func testAQueueAlreadyHoldingAFolderItemMovesItForwardAndKeepsTheRestBehind() {
        var queue = PlayQueue(itemIds: ["other-1", "i4", "other-2"])
        queue.playNext(contentsOf: ["i2", "i3", "i4"])
        XCTAssertEqual(queue.itemIds, ["i2", "i3", "i4", "other-1", "other-2"])
        queue.playNext(contentsOf: ["i2", "i3", "i4"])
        XCTAssertEqual(queue.itemIds, ["i2", "i3", "i4", "other-1", "other-2"], "tapped twice, each item once and in order")
        queue.playNext(contentsOf: [String]())
        XCTAssertEqual(queue.itemIds, ["i2", "i3", "i4", "other-1", "other-2"])
        queue.playNext(contentsOf: ["i9", "i9", "other-2"])
        XCTAssertEqual(queue.itemIds, ["i9", "other-2", "i2", "i3", "i4", "other-1"], "a repeated id counts once")
    }

    // MARK: Words

    func testTheRowSaysWhatIsLeft() throws {
        let progress = try self.progress([.finished(at: 10), .none, .percent(30, at: 20)])
        XCTAssertEqual(progress.detailLine, "3 items · 2 unfinished")
        XCTAssertEqual(LibraryCollectionProgress(collection: ItemCollection(id: "f", name: "Daily Brief", itemIDs: progress.itemIDs, createdAt: base),
                                                 rows: try rows()).accessibilityLabel, "Daily Brief, collection, 3 items, 2 unfinished")
    }

    func testSingularsAndAllFinished() throws {
        let finished = try self.progress([.finished(at: 10)])
        XCTAssertEqual(finished.detailLine, "1 item · all finished")
        XCTAssertEqual(finished.accessibilityLabel, "Brief, collection, 1 item, all finished")
        XCTAssertTrue(finished.isAllFinished)
        let withFailure = LibraryCollectionProgress(collection: collection(["i1"]), imported: folder([member(1)], notAdded: 1), rows: try rows())
        XCTAssertEqual(withFailure.detailLine, "1 item · all finished · 1 not added")
        XCTAssertEqual(LibraryCollectionProgress(collection: collection(["i1"]), rows: [:]).detailLine, "No items",
                       "an item that is not a row is not live")
    }

    func testTheDetailLineForEveryDesignedState() throws {
        try save(Array(repeating: .none, count: 24))
        let all = try rows()
        let ids = (1...24).map { "i\($0)" }
        let importing = (1...3).map { member($0) } + (4...24).map { member($0, state: .adding) }
        XCTAssertEqual(LibraryCollectionProgress(collection: collection(Array(ids.prefix(3))), imported: folder(importing), rows: all).detailLine,
                       "Adding 3 of 24…")
        XCTAssertEqual(LibraryCollectionProgress(collection: collection(Array(ids.prefix(22))), imported: folder((1...22).map { member($0) }, notAdded: 2),
                                                 rows: all).detailLine, "22 items · 22 unfinished · 2 not added")
        XCTAssertEqual(LibraryCollectionProgress(collection: collection([]), rows: all).detailLine, "No items")
        XCTAssertEqual(LibraryCollectionProgress(collection: collection([]), imported: folder((1...3).map { member($0, state: .failed) }),
                                                 rows: all).detailLine, "3 not added")
        XCTAssertEqual(LibraryCollectionProgress(collection: collection([]), imported: folder([member(1, state: .failed)]), rows: all).detailLine,
                       "1 not added")
    }

    func testMarginAndSharedLines() throws {
        let progress = try self.progress([.none, .none, .none]) { rows in
            rows["i1"]?.marginCount = 2
            rows["i2"]?.marginCount = 3
            rows["i3"]?.sharedMargins = SharedMarginTally(total: 1, new: 1)
        }
        XCTAssertEqual(progress.marginLine, "5 Margins")
        XCTAssertEqual(progress.sharedLine, "New shared Margins in 1 item")
        let more = try self.progress([.none]) { rows in
            rows["i1"]?.marginCount = 1
            rows["i1"]?.sharedMargins = SharedMarginTally(total: 2, new: 2)
        }
        XCTAssertEqual(more.marginLine, "1 Margin")
        XCTAssertNil(try self.progress([.none]).marginLine)
        XCTAssertNil(try self.progress([.none]).sharedLine, "only a shared Margin the listener has not heard")
    }

    func testAddToQueueTakesTheUnfinishedItemsInOrderAndEverythingWhenAllAreFinished() throws {
        let some = try self.progress([.finished(at: 10), .none, .percent(30, at: 20)])
        XCTAssertEqual(LibraryCollectionQueueing.itemsToQueue(some), ["i2", "i3"])
        var queue = PlayQueue(itemIds: ["other", "i3"])
        XCTAssertEqual(queue.append(contentsOf: LibraryCollectionQueueing.itemsToQueue(some)), 1, "i3 was already queued")
        XCTAssertEqual(queue.itemIds, ["other", "i3", "i2"], "an item already queued keeps its place")
        XCTAssertEqual(LibraryCollectionQueueing.banner(added: 1, name: "Brief"), "Added 1 from “Brief” to the queue.")
        XCTAssertEqual(LibraryCollectionQueueing.banner(added: 0, name: "Brief"), "Everything in “Brief” is already in the queue.")
    }

    func testAddToQueueOnAnAllFinishedCollectionQueuesEveryItem() throws {
        let done = try self.progress([.finished(at: 10), .markedComplete])
        XCTAssertEqual(LibraryCollectionQueueing.itemsToQueue(done), ["i1", "i2"])
    }

    func testTheItemStateWordsAreAlwaysShownWithTheGlyph() {
        XCTAssertEqual(LibraryCollectionProgress.ItemState.notStarted.word, "Not started")
        XCTAssertEqual(LibraryCollectionProgress.ItemState.partWay(percent: 40).word, "40%")
        XCTAssertEqual(LibraryCollectionProgress.ItemState.finished.word, "Finished")
        XCTAssertEqual(LibraryCollectionProgress.ItemState.notStarted.symbol, "circle")
        XCTAssertEqual(LibraryCollectionProgress.ItemState.partWay(percent: 40).symbol, "circle.lefthalf.filled")
        XCTAssertEqual(LibraryCollectionProgress.ItemState.finished.symbol, "checkmark.circle.fill")
    }
}
