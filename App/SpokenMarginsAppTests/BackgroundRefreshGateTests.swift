import XCTest
@testable import SpokenMarginsApp

/// #2102: a reload read off the main thread may publish only while nothing newer has happened. The first version of
/// the Library and item refreshes had no such check in a test, so a slow read could overwrite a newer screen.
@MainActor
final class BackgroundRefreshGateTests: XCTestCase {
    func testANewerReloadOvertakesTheOneInFlight() {
        let gate = BackgroundRefreshGate()
        let first = gate.beginItem()
        XCTAssertTrue(gate.isCurrentItem(first))
        let second = gate.beginItem()
        XCTAssertFalse(gate.isCurrentItem(first), "the older read must not publish after a newer one began")
        XCTAssertTrue(gate.isCurrentItem(second))
    }

    func testAnotherAssignmentToTheSelectedItemOvertakesTheReload() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.selectionWasAssigned()
        XCTAssertFalse(gate.isCurrentItem(reload), "opening another item while a read is in flight drops that read")
    }

    func testPublishingTheReloadItselfDoesNotInvalidateIt() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.publishItem {
            gate.selectionWasAssigned() // the didSet fires for our own assignment
        }
        XCTAssertTrue(gate.isCurrentItem(reload))
    }

    func testTheLibraryAndItemGenerationsAreIndependent() {
        let gate = BackgroundRefreshGate()
        let item = gate.beginItem()
        let library = gate.beginLibrary()
        _ = gate.beginLibrary()
        XCTAssertFalse(gate.isCurrentLibrary(library))
        XCTAssertTrue(gate.isCurrentItem(item), "a newer Library read leaves the item reload alone")
    }
}
