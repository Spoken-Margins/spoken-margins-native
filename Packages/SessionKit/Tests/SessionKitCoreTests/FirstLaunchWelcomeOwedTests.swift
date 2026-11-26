import XCTest
@testable import SessionKit

/// #4711 Design section 3: the cold-install welcome is owed to `FirstLaunchWelcomeOrder`, plays on settle wherever the
/// listener is, and gives way to a friend's file.
final class FirstLaunchWelcomeOwedTests: XCTestCase {
    typealias Order = FirstLaunchWelcomeOrder

    func testWelcomePlaysOnSettleWithNoFriendFile() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        XCTAssertEqual(order.moved(to: .library), .none, "not before the launch settles: a file may be on its way")
        XCTAssertEqual(order.settle(at: .elsewhere), .playWelcome, "any settled place counts, not only the Library")
        XCTAssertEqual(order.moved(to: .library), .none, "once")
        XCTAssertEqual(order.entry, .coldInstall)
    }

    func testWelcomeIsNotOwedByDefault() {
        var order = Order(drawerOwed: false)
        XCTAssertEqual(order.settle(at: .library), .none)
        XCTAssertFalse(order.welcomeOwed)
    }

    func testFriendFileHoldsWelcomeBack() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .none)
        XCTAssertEqual(order.settle(at: .library), .none)
        XCTAssertEqual(order.moved(to: .item), .none)
        XCTAssertFalse(order.welcomeOwed)
    }

    func testEntryIsFriendArrival() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        XCTAssertEqual(order.entry, .coldInstall)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.entry, .friendArrival)
        XCTAssertTrue(order.wasHeldBack)
    }

    func testFriendLinkHoldsWelcomeBack() {
        // Links report through the same call as files (#4711 Design table).
        var order = Order(drawerOwed: true, welcomeOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.settle(at: .library), .none)
        order.friendItemOpened()
        XCTAssertEqual(order.moved(to: .library), .presentDrawer, "the drawer still follows the friend's item")
        XCTAssertEqual(order.entry, .friendArrival)
    }

    func testFailedFriendFileOwesWelcomeAgain() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.settle(at: .library), .none)
        XCTAssertEqual(order.friendFileFailed(place: .elsewhere), .playWelcome, "settled, so it plays at once")
        XCTAssertEqual(order.entry, .coldInstall, "the entry is back to cold_install, though the welcome has now played")
    }

    func testFailedFriendFileBeforeSettleWaitsForSettle() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.friendFileFailed(place: .library), .none)
        XCTAssertTrue(order.welcomeOwed)
        XCTAssertEqual(order.entry, .coldInstall)
        XCTAssertEqual(order.settle(at: .library), .playWelcome)
    }

    func testAFailureAfterTheFriendItemOpenedDoesNotGiveTheWelcomeBack() {
        var order = Order(drawerOwed: false, welcomeOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        order.friendItemOpened()
        XCTAssertEqual(order.friendFileFailed(place: .library), .none)
        XCTAssertEqual(order.settle(at: .library), .none)
        XCTAssertEqual(order.entry, .friendArrival)
        XCTAssertTrue(order.reachedFriendItem)
    }

    func testAFileThatArrivesAfterTheWelcomeStartedDoesNotChangeTheEntry() {
        // Default taken 2.
        var order = Order(drawerOwed: false, welcomeOwed: true)
        XCTAssertEqual(order.settle(at: .library), .playWelcome)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.entry, .coldInstall)
    }

    func testWelcomeGoesBeforeTheDrawerWhenBothAreOwed() {
        // Default taken 5.
        var order = Order(drawerOwed: true, welcomeOwed: true)
        XCTAssertEqual(order.settle(at: .library), .playWelcome)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer, "the drawer waits for the next Library visit")
        XCTAssertEqual(order.entry, .coldInstall)
    }

    func testAnEarlierLaunchsHeldBackFileMeansNoWelcome() {
        var order = Order(drawerOwed: true, owedFromEarlierLaunch: true, welcomeOwed: true)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertEqual(order.entry, .friendArrival)
    }
}
