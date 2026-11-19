import Foundation
import XCTest
@testable import SessionKit

final class ItemQuickActionsTests: XCTestCase {
    private func row(completed: Bool, canMarkUnfinished: Bool = false, newMargins: Int = 0, offline: LibraryOfflineStateFilter = .onlineOnly) -> LibraryItemRow {
        var row = LibraryItemRow(id: "item", title: "Item", status: "ready", canDelete: true, isCompleted: completed)
        row.canMarkUnfinished = canMarkUnfinished
        row.sharedMargins = SharedMarginTally(total: newMargins, new: newMargins)
        row.offlineState = offline
        return row
    }

    func testAnItemNotYetCompleteOffersCompleteQueueCollectionAndOffline() {
        XCTAssertEqual(ItemQuickAction.actions(for: row(completed: false)), [.markComplete, .playNext, .addToQueue, .addToCollection, .prepareOffline])
    }

    func testAnItemMarkedCompleteByHandOffersMarkUnfinished() {
        XCTAssertEqual(
            ItemQuickAction.actions(for: row(completed: true, canMarkUnfinished: true)),
            [.markUnfinished, .playNext, .addToQueue, .addToCollection, .prepareOffline]
        )
    }

    func testAnItemFinishedByListeningOffersNeitherCompletionAction() {
        XCTAssertEqual(ItemQuickAction.actions(for: row(completed: true)), [.playNext, .addToQueue, .addToCollection, .prepareOffline])
    }

    func testAnItemAlreadyOfflineHasNoPrepareOffline() {
        XCTAssertEqual(
            ItemQuickAction.actions(for: row(completed: false, offline: .readyOffline)),
            [.markComplete, .playNext, .addToQueue, .addToCollection]
        )
    }

    /// The item screen's visible button and its menu entry read the same rule (#2393).
    func testTheVisibleCompletionButtonFollowsTheMenuRule() {
        XCTAssertEqual(ItemQuickAction.completionAction(for: row(completed: false)), .markComplete)
        XCTAssertEqual(ItemQuickAction.completionAction(for: row(completed: true, canMarkUnfinished: true)), .markUnfinished)
        XCTAssertNil(ItemQuickAction.completionAction(for: row(completed: true)), "finished by listening: nothing to undo")
        for completed in [false, true] {
            for byHand in [false, true] {
                for newMargins in [0, 2] {
                    let r = row(completed: completed, canMarkUnfinished: byHand, newMargins: newMargins)
                    XCTAssertEqual(ItemQuickAction.actions(for: r).first(where: { $0 == .markComplete || $0 == .markUnfinished || $0 == .markMarginsHeard }),
                                   ItemQuickAction.completionAction(for: r))
                }
            }
        }
    }

    /// #4289: a finished item that stays under Unfinished for a friend's new Margins had no action that could clear it.
    func testAFinishedItemWithNewSharedMarginsOffersMarkMarginsHeard() {
        for byHand in [false, true] {
            XCTAssertEqual(ItemQuickAction.completionAction(for: row(completed: true, canMarkUnfinished: byHand, newMargins: 3)), .markMarginsHeard,
                           "finished by listening or by hand, the Margins are what is left to clear")
        }
        XCTAssertEqual(
            ItemQuickAction.actions(for: row(completed: true, newMargins: 1)),
            [.markMarginsHeard, .playNext, .addToQueue, .addToCollection, .prepareOffline])
        XCTAssertEqual(
            ItemQuickAction.completionActions(for: row(completed: true, canMarkUnfinished: true, newMargins: 1)),
            [.markMarginsHeard, .markUnfinished], "a hand-marked item keeps Mark Not Complete in the menu")
    }

    func testMarkMarginsHeardIsOnlyOfferedWhenThereIsSomethingToMark() {
        XCTAssertFalse(ItemQuickAction.completionActions(for: row(completed: true, newMargins: 0)).contains(.markMarginsHeard))
        XCTAssertEqual(ItemQuickAction.completionActions(for: row(completed: false, newMargins: 2)), [.markComplete],
                       "an unfinished item leaves Unfinished by being completed, as before")
    }
}
