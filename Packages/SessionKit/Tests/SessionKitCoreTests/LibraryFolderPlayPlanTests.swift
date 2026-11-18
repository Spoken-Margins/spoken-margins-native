import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3769: where a folder's ▶ starts, what it queues behind it, and the words the row and screen use. Rows come from a real
/// temporary store through `LibraryRowBuilder`, so "finished" is whatever `ItemFinishedRule` says.
final class LibraryFolderPlayPlanTests: XCTestCase {
    private var store: SQLiteSessionStore!
    private let context = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true)
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        store = try SQLiteSessionStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-plan-\(UUID().uuidString).sqlite").path)
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

    private func progress(_ listening: [Listening], tweak: (inout [String: LibraryItemRow]) -> Void = { _ in }) throws -> LibraryFolderProgress {
        try save(listening)
        var all = try rows()
        tweak(&all)
        return LibraryFolderProgress(folder: folder((1...listening.count).map { member($0) }), rows: all)
    }

    private func resume(_ listening: [Listening], tweak: (inout [String: LibraryItemRow]) -> Void = { _ in }) throws -> LibraryFolderPlayPlan {
        try XCTUnwrap(LibraryFolderPlayPlan.resume(try progress(listening, tweak: tweak)))
    }

    // MARK: The play rule

    func testAFolderNobodyHasListenedToStartsAtItemOneAndQueuesTheRest() throws {
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
        XCTAssertEqual(plan.label, .continue, "something in the folder was heard")
        XCTAssertEqual(plan.startItemID, "i2")
        XCTAssertEqual(plan.queuedItemIDs, ["i3"])
    }

    func testEachFinishedCaseOnItsOwn() throws {
        try save([.percent(99, at: 10), .finished(at: 20), .markedComplete,
                  .finishedThenAddedAgain(finishedAt: 30, addedAgainAt: 100), .percent(98, at: 40), .none])
        let all = try rows()
        let state = { (id: String) in LibraryFolderProgress.state(of: all[id]!) }
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

    func testNewSharedMarginsDoNotChangeAFolderThatHasUnfinishedItems() throws {
        let plan = try resume([.finished(at: 10), .none]) { rows in
            rows["i1"]?.sharedMargins = SharedMarginTally(total: 1, new: 1)
        }
        XCTAssertEqual(plan.startItemID, "i2")
    }

    func testAnEmptyFolderHasNoPlanAndNoLiveItemsMeansNone() throws {
        XCTAssertNil(LibraryFolderPlayPlan.resume(LibraryFolderProgress(folder: folder([]), rows: [:])))
        let arriving = LibraryFolderProgress(folder: folder([member(1, state: .adding)]), rows: [:])
        XCTAssertNil(LibraryFolderPlayPlan.resume(arriving), "disabled until the first item is in")
        XCTAssertFalse(arriving.canPlay)
    }

    func testPlayFromHereOnTheLastItemQueuesNothing() throws {
        let progress = try self.progress([.none, .none, .none])
        let plan = try XCTUnwrap(LibraryFolderPlayPlan.playFrom(itemID: "i3", progress))
        XCTAssertEqual(plan.startItemID, "i3")
        XCTAssertEqual(plan.queuedItemIDs, [])
        XCTAssertEqual(plan.banner(folderName: "Brief"), "Playing “Brief”.")
    }

    func testPlayFromHereQueuesTheUnfinishedItemsAfterIt() throws {
        let progress = try self.progress([.none, .none, .finished(at: 10), .none, .percent(5, at: 20)])
        let plan = try XCTUnwrap(LibraryFolderPlayPlan.playFrom(itemID: "i2", progress))
        XCTAssertEqual(plan.queuedItemIDs, ["i4", "i5"])
        XCTAssertEqual(plan.banner(folderName: "Brief"), "Playing “Brief” · 2 more in the queue.")
        XCTAssertEqual(try XCTUnwrap(LibraryFolderPlayPlan.playFrom(itemID: "i4", progress)).banner(folderName: "Brief"),
                       "Playing “Brief” · 1 more in the queue.")
        XCTAssertNil(LibraryFolderPlayPlan.playFrom(itemID: "elsewhere", progress), "not an item of this folder")
    }

    func testPlayFromHereWhenEverythingIsFinishedLinesUpTheRest() throws {
        let progress = try self.progress([.finished(at: 10), .finished(at: 20), .finished(at: 30)])
        let plan = try XCTUnwrap(LibraryFolderPlayPlan.playFrom(itemID: "i2", progress))
        XCTAssertEqual(plan.queuedItemIDs, ["i3"])
        XCTAssertEqual(plan.label, .playAgain)
    }

    func testTheLabelsSayWhatVoiceOverShouldRead() {
        XCTAssertEqual(LibraryFolderPlayPlan.Label.start.accessibilityLabel(folderName: "Daily Brief"), "Start Daily Brief")
        XCTAssertEqual(LibraryFolderPlayPlan.Label.continue.accessibilityLabel(folderName: "Daily Brief"), "Continue Daily Brief")
        XCTAssertEqual(LibraryFolderPlayPlan.Label.playAgain.accessibilityLabel(folderName: "Daily Brief"), "Play Daily Brief again")
        XCTAssertEqual(LibraryFolderPlayPlan.Label.playAgain.rawValue, "Play Again")
    }

    // MARK: Which items are live

    func testRemovedFailedArrivingAndDeletedMembersAreNotItems() throws {
        try save([.none, .none, .none, .none, .none])
        try store.moveItemToTrash(id: "i3")
        let members = [member(1), member(2, state: .removed), member(3), member(4, state: .failed), member(5, state: .adding)]
        let progress = LibraryFolderProgress(folder: folder(members, notAdded: 1), rows: try rows())
        XCTAssertEqual(progress.entries.map(\.itemID), ["i1"], "a deleted item is in no row and no count")
        XCTAssertEqual(progress.entries.map(\.number), [1])
        XCTAssertEqual(progress.addingCount, 1)
        XCTAssertEqual(progress.notAddedCount, 2, "the failed member and the walk's named file")
    }

    func testNumbersCountLiveItemsOnlySoTheyMatchTheFolderScreen() throws {
        try save([.none, .none, .none])
        let progress = LibraryFolderProgress(folder: folder([member(1, state: .removed), member(2), member(3)]), rows: try rows())
        XCTAssertEqual(progress.entries.map(\.number), [1, 2])
        XCTAssertEqual(progress.entries.map(\.itemID), ["i2", "i3"])
        XCTAssertEqual(progress.entries[0].accessibilityLabel(of: 2), "1 of 2, Not started, Item 2")
    }

    func testAnUpdatedCopyIsMarked() throws {
        try save([.none, .none])
        var copy = member(2)
        copy.updatedCopyOf = "1.pdf"
        let progress = LibraryFolderProgress(folder: folder([member(1), copy]), rows: try rows())
        XCTAssertEqual(progress.entries.map(\.isUpdatedCopy), [false, true])
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
        XCTAssertEqual(progress.accessibilityLabel(folderName: "Daily Brief"), "Daily Brief, folder, 3 items, 2 unfinished")
    }

    func testSingularsAndAllFinished() throws {
        var finished = try self.progress([.finished(at: 10)])
        XCTAssertEqual(finished.detailLine, "1 item · all finished")
        XCTAssertEqual(finished.accessibilityLabel(folderName: "A"), "A, folder, 1 item, all finished")
        XCTAssertTrue(finished.isAllFinished)
        let rowsNow = try rows()
        finished = LibraryFolderProgress(folder: folder([member(1)], notAdded: 1), rows: rowsNow)
        XCTAssertEqual(finished.detailLine, "1 item · all finished · 1 not added")
        let open = LibraryFolderProgress(folder: folder([member(1)]), rows: [:])
        XCTAssertEqual(open.detailLine, "Empty folder", "an item that is not a row is not live")
    }

    func testTheDetailLineForEveryDesignedState() throws {
        try save(Array(repeating: .none, count: 24))
        let all = try rows()
        let twentyTwoOfTwentyFour = (1...22).map { member($0) }
        let importing = (1...3).map { member($0) } + (4...24).map { member($0, state: .adding) }
        XCTAssertEqual(LibraryFolderProgress(folder: folder(importing), rows: all).detailLine, "Adding 3 of 24…")
        XCTAssertEqual(LibraryFolderProgress(folder: folder(twentyTwoOfTwentyFour, notAdded: 2), rows: all).detailLine,
                       "22 items · 22 unfinished · 2 not added")
        XCTAssertEqual(LibraryFolderProgress(folder: folder([]), rows: all).detailLine, "Empty folder")
        XCTAssertEqual(LibraryFolderProgress(folder: folder([member(1, state: .failed), member(2, state: .failed), member(3, state: .failed)]),
                                             rows: all).detailLine, "3 not added")
        XCTAssertEqual(LibraryFolderProgress(folder: folder([member(1, state: .failed)]), rows: all).detailLine, "1 not added")
        XCTAssertEqual(LibraryFolderProgress(folder: folder([member(1, state: .removed)]), rows: all).detailLine, "Empty folder",
                       "everything removed")
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

    func testTheItemStateWordsAreAlwaysShownWithTheGlyph() {
        XCTAssertEqual(LibraryFolderProgress.ItemState.notStarted.word, "Not started")
        XCTAssertEqual(LibraryFolderProgress.ItemState.partWay(percent: 40).word, "40%")
        XCTAssertEqual(LibraryFolderProgress.ItemState.finished.word, "Finished")
        XCTAssertEqual(LibraryFolderProgress.ItemState.notStarted.symbol, "circle")
        XCTAssertEqual(LibraryFolderProgress.ItemState.partWay(percent: 40).symbol, "circle.lefthalf.filled")
        XCTAssertEqual(LibraryFolderProgress.ItemState.finished.symbol, "checkmark.circle.fill")
    }
}
