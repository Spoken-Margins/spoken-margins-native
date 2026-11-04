import XCTest
@testable import SessionKit

/// #3291 done-when 4: on a first launch opened from a friend's file, the friend's item comes before the favourites
/// drawer and the Welcome article it plays.
final class FirstLaunchWelcomeOrderTests: XCTestCase {
    typealias Order = FirstLaunchWelcomeOrder

    func testAFreshInstallWithNoFileOpensTheDrawerOnceTheLaunchSettles() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.moved(to: .library), .none, "not before the launch has settled: a file may be on its way")
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertEqual(order.phase, .drawerShowing)
        order.drawerClosed()
        XCTAssertEqual(order.moved(to: .library), .none, "once")
    }

    func testAFileOpenedWithTheAppComesFirstAndTheDrawerWaitsForTheLibrary() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .none)
        XCTAssertTrue(order.defersDrawer)
        XCTAssertEqual(order.settle(at: .library), .none, "the friend's item hasn't opened yet")
        XCTAssertEqual(order.moved(to: .elsewhere), .none, "the import review is up")
        XCTAssertEqual(order.moved(to: .library), .none)
        XCTAssertEqual(order.moved(to: .item), .none, "the friend's item opened")
        XCTAssertEqual(order.moved(to: .elsewhere), .none, "playing it")
        XCTAssertEqual(order.moved(to: .item), .none)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer, "back on the Library")
        XCTAssertFalse(order.defersDrawer)
    }

    func testAFileThatArrivesAfterTheDrawerOpenedTakesItsPlace() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .withdrawDrawer)
        XCTAssertEqual(order.phase, .waitingForFriendItem)
        XCTAssertEqual(order.moved(to: .item), .none)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer)
    }

    func testADrawerTheListenerHasPickedInStaysWhenAFileArrives() {
        var order = Order(drawerOwed: true)
        _ = order.settle(at: .library)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: true), .none)
        XCTAssertEqual(order.phase, .drawerShowing)
        order.drawerClosed()
        XCTAssertEqual(order.moved(to: .library), .none)
    }

    func testAFileWhoseItemNeverOpensLeavesTheDrawerOwedToTheNextLaunch() {
        var order = Order(drawerOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertEqual(order.settle(at: .library), .none, "refused or cancelled: no item opened")
        XCTAssertTrue(order.defersDrawer, "the app keeps this for the next launch")
        XCTAssertTrue(Order.drawerOwed(libraryWasEmptyAtLaunch: false, deferredFromEarlierLaunch: true, hasSeenDrawer: false, followedSourceCount: 0),
                      "the friend's item made the Library non-empty; the drawer is still owed")
    }

    func testTheDrawerWaitsForTheLibraryNotAnItemOrASheet() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.settle(at: .item), .none)
        XCTAssertEqual(order.moved(to: .elsewhere), .none)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer)
    }

    func testALaunchThatDoesntOweTheDrawerIgnoresFiles() {
        var order = Order(drawerOwed: false)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .none)
        XCTAssertFalse(order.defersDrawer, "an upgraded Library's friend's file owes nothing to a later launch")
        XCTAssertEqual(order.settle(at: .library), .none)
        XCTAssertEqual(order.moved(to: .item), .none)
        XCTAssertEqual(order.moved(to: .library), .none)
    }

    func testASecondFileWhileWaitingChangesNothing() {
        var order = Order(drawerOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        _ = order.moved(to: .item)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .none)
        XCTAssertEqual(order.phase, .waitingForLibrary)
    }

    func testWhoIsOwedTheDrawer() {
        XCTAssertTrue(Order.drawerOwed(libraryWasEmptyAtLaunch: true, deferredFromEarlierLaunch: false, hasSeenDrawer: false, followedSourceCount: 0))
        XCTAssertFalse(Order.drawerOwed(libraryWasEmptyAtLaunch: false, deferredFromEarlierLaunch: false, hasSeenDrawer: false, followedSourceCount: 0), "upgraded Library")
        XCTAssertFalse(Order.drawerOwed(libraryWasEmptyAtLaunch: true, deferredFromEarlierLaunch: true, hasSeenDrawer: true, followedSourceCount: 0), "once")
        XCTAssertFalse(Order.drawerOwed(libraryWasEmptyAtLaunch: false, deferredFromEarlierLaunch: true, hasSeenDrawer: false, followedSourceCount: 1), "already following")
    }
}
