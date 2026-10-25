import Foundation
import XCTest
@testable import SessionKit

final class ItemQuickActionsTests: XCTestCase {
    private func row(completed: Bool, canMarkUnfinished: Bool = false, offline: LibraryOfflineStateFilter = .onlineOnly) -> LibraryItemRow {
        var row = LibraryItemRow(id: "item", title: "Item", status: "ready", canDelete: true, isCompleted: completed)
        row.canMarkUnfinished = canMarkUnfinished
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
                let r = row(completed: completed, canMarkUnfinished: byHand)
                XCTAssertEqual(ItemQuickAction.actions(for: r).first(where: { $0 == .markComplete || $0 == .markUnfinished }),
                               ItemQuickAction.completionAction(for: r))
            }
        }
    }
}
