import Foundation
import XCTest
@testable import SessionKit

/// "Review new Margins" (#474) owes the listener their place back. These cover the note that lets the app give it
/// back after Add Margin or a relaunch, when the review itself never got to.
final class ReviewReturnPlaceTests: XCTestCase {
    private func review(returnTo: Int? = 12_000, margins: [Int] = [1_000, 25_000]) -> MarginMomentSequence {
        MarginMomentSequence(
            itemId: "ep",
            reviewing: margins.enumerated().map { MarginMomentAnchor(marginId: "m\($0.offset)", mediaTimeMs: $0.element) },
            returnToMediaTimeMs: returnTo
        )!
    }

    /// A defaults suite of its own, removed afterwards, so no test reads or leaves what another wrote.
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ReviewReturnPlaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testAReviewOwesThePlaceTheListenerLeftOff() throws {
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review()))
        XCTAssertEqual(place.itemId, "ep")
        XCTAssertEqual(place.returnToMediaTimeMs, 12_000)
    }

    func testAMomentThatIsNotAReviewOrHasNoPlaceOwesNothing() {
        let single = MarginMomentSequence(
            itemId: "ep", target: MarginMomentAnchor(marginId: "m", mediaTimeMs: 5_000), otherMargins: []
        )
        XCTAssertNil(ReviewReturnPlace(sequence: single))
        XCTAssertNil(ReviewReturnPlace(sequence: review(returnTo: nil)))
    }

    func testOnlyPositionsTheReviewCouldHavePutTheSourceAtNeedRestoring() throws {
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review()))
        XCTAssertTrue(place.needsRestoring(from: 25_000), "left at the last Margin")
        XCTAssertTrue(place.needsRestoring(from: 0), "left at the first lead-in")
        XCTAssertTrue(place.needsRestoring(from: 25_000 + ReviewReturnPlace.slackMs), "just past the last Margin")
        XCTAssertFalse(place.needsRestoring(from: 12_000), "already where they left off")
        XCTAssertFalse(place.needsRestoring(from: 12_000 + ReviewReturnPlace.alreadyThereMs), "close enough to be there")
        XCTAssertFalse(place.needsRestoring(from: 25_000 + ReviewReturnPlace.slackMs + 1), "the listener listened on")
        XCTAssertFalse(place.needsRestoring(from: nil), "nothing was saved")
    }

    /// Audit of #3619: the episode plays on after a Margin, so a relaunch between Margins must leave the listener where they
    /// are, not at the place the review started from, even a place only seconds into the episode.
    func testThePlaceIsNotOwedOnceAMarginHasPlayedUnlessTheListenerWasAhead() throws {
        let behind = try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 2_000, margins: [60_000, 2_312_000])))
        XCTAssertTrue(behind.needsRestoring(from: 720_000), "what a relaunch between the Margins would have done")
        XCTAssertFalse(behind.isOwed(onceMarginAt: 60_000), "the first Margin played: the listener stays where they are")
        XCTAssertFalse(behind.isOwed(onceMarginAt: 2_312_000))
        let ahead = try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 900_000, margins: [60_000, 2_312_000])))
        XCTAssertTrue(ahead.isOwed(onceMarginAt: 60_000), "they were further on, so they are brought back")
        XCTAssertFalse(ahead.isOwed(onceMarginAt: 2_312_000), "the last Margin is past their place")
        XCTAssertFalse(ahead.isOwed(onceMarginAt: 900_000), "a Margin at their own place owes nothing")
    }

    func testAPositionBeforeTheReviewStartedIsTheListenersOwn() throws {
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 90_000, margins: [40_000, 60_000])))
        XCTAssertFalse(place.needsRestoring(from: place.stretchStartMs - 1), "scrubbed to before the review's stretch")
        XCTAssertTrue(place.needsRestoring(from: 60_000))
    }

    func testThePlaceSurvivesALaunchAndIsKeptPerItem() throws {
        try withIsolatedDefaults { defaults in
            ReviewReturnPlaces(defaults: defaults).owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
            let afterRelaunch = ReviewReturnPlaces(defaults: defaults)
            XCTAssertEqual(afterRelaunch.owed(itemId: "ep")?.returnToMediaTimeMs, 12_000)
            XCTAssertNil(afterRelaunch.owed(itemId: "another"))
        }
    }

    func testClearingAPlaceForgetsItAndLeavesNothingBehind() throws {
        try withIsolatedDefaults { defaults in
            let places = ReviewReturnPlaces(defaults: defaults)
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
            XCTAssertNotNil(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep"))
            places.clear(itemId: "ep")
            XCTAssertNil(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep"))
            XCTAssertNil(defaults.data(forKey: "spokenmargins.reviewReturnPlaces"), "nothing left behind")
        }
    }

    func testRemovingAllForgetsEveryItemsPlace() throws {
        try withIsolatedDefaults { defaults in
            let places = ReviewReturnPlaces(defaults: defaults)
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
            let other = try XCTUnwrap(MarginMomentSequence(
                itemId: "other", reviewing: [MarginMomentAnchor(marginId: "x", mediaTimeMs: 9_000)], returnToMediaTimeMs: 2_000
            ))
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: other)))
            places.removeAll()
            XCTAssertNil(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep"))
            XCTAssertNil(ReviewReturnPlaces(defaults: defaults).owed(itemId: "other"))
        }
    }

    func testClearingAnItemThatOwesNothingChangesNothing() {
        withIsolatedDefaults { defaults in
            let places = ReviewReturnPlaces(defaults: defaults)
            places.clear(itemId: "ep")
            XCTAssertNil(places.owed(itemId: "ep"))
            XCTAssertNil(defaults.data(forKey: "spokenmargins.reviewReturnPlaces"))
        }
    }

    func testAnotherReviewOfTheSameItemReplacesThePlace() throws {
        try withIsolatedDefaults { defaults in
            let places = ReviewReturnPlaces(defaults: defaults)
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 12_000))))
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 3_000))))
            XCTAssertEqual(places.owed(itemId: "ep")?.returnToMediaTimeMs, 3_000)
        }
    }

    func testGarbageInTheStoreIsIgnored() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: "spokenmargins.reviewReturnPlaces")
            let places = ReviewReturnPlaces(defaults: defaults)
            XCTAssertNil(places.owed(itemId: "ep"))
            places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
            XCTAssertEqual(places.owed(itemId: "ep")?.returnToMediaTimeMs, 12_000)
        }
    }
}
