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

    // MARK: Held back by a friend's file (#3795, #3796)

    func testAFreshInstallWithNoFileMayPlayTheWelcomeSampleOnClose() {
        var order = Order(drawerOwed: true)
        XCTAssertTrue(order.playsWelcomeSampleOnClose)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertTrue(order.playsWelcomeSampleOnClose, "J11: Done with nothing picked still plays the Welcome sample")
        XCTAssertFalse(order.wasHeldBack)
    }

    func testAFileThatHeldTheDrawerBackStopsTheWelcomeSampleEvenOnceTheDrawerShows() {
        var order = Order(drawerOwed: true)
        _ = order.friendFileArrived(drawerHasPicks: false)
        XCTAssertFalse(order.playsWelcomeSampleOnClose)
        _ = order.settle(at: .library)
        _ = order.moved(to: .item)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer)
        XCTAssertFalse(order.playsWelcomeSampleOnClose, "same launch: the held-back state survives the drawer opening")
        order.drawerClosed()
        XCTAssertFalse(order.playsWelcomeSampleOnClose)
    }

    func testAFileThatWithdrewTheDrawerCountsAsHeldBack() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertTrue(order.playsWelcomeSampleOnClose)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: false), .withdrawDrawer)
        XCTAssertFalse(order.playsWelcomeSampleOnClose)
        XCTAssertEqual(order.moved(to: .item), .none)
        XCTAssertEqual(order.moved(to: .library), .presentDrawer, "the drawer still returns after the friend's item")
    }

    func testADrawerTheListenerAlreadyPickedInIsNotHeldBack() {
        var order = Order(drawerOwed: true)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertEqual(order.friendFileArrived(drawerHasPicks: true), .none)
        XCTAssertTrue(order.playsWelcomeSampleOnClose, "the picks play; the friend's item is handled by the drawer's own guard")
    }

    func testADrawerOwedFromAnEarlierLaunchCountsAsHeldBack() {
        var order = Order(drawerOwed: true, owedFromEarlierLaunch: true)
        XCTAssertTrue(order.wasHeldBack)
        XCTAssertFalse(order.playsWelcomeSampleOnClose)
        XCTAssertEqual(order.settle(at: .library), .presentDrawer)
        XCTAssertFalse(order.playsWelcomeSampleOnClose)
    }

    func testALeftoverEarlierLaunchFlagMeansNothingWhenTheDrawerIsNotOwed() {
        let order = Order(drawerOwed: false, owedFromEarlierLaunch: true)
        XCTAssertFalse(order.wasHeldBack)
        XCTAssertTrue(order.playsWelcomeSampleOnClose)
    }
}
