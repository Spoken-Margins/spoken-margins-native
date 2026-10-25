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
}
