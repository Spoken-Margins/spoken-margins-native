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

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ReviewReturnPlaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAReviewOwesThePlaceTheListenerLeftOff() throws {
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review()))
        XCTAssertEqual(place.itemId, "ep")
        XCTAssertEqual(place.returnToMediaTimeMs, 12_000)
        XCTAssertFalse(place.keptForRecording)
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

    func testAPositionBeforeTheReviewStartedIsTheListenersOwn() throws {
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 90_000, margins: [40_000, 60_000])))
        XCTAssertFalse(place.needsRestoring(from: place.stretchStartMs - 1), "scrubbed to before the review's stretch")
        XCTAssertTrue(place.needsRestoring(from: 60_000))
    }

    func testThePlaceSurvivesALaunchAndIsKeptPerItem() throws {
        let defaults = isolatedDefaults()
        ReviewReturnPlaces(defaults: defaults).owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
        let afterRelaunch = ReviewReturnPlaces(defaults: defaults)
        XCTAssertEqual(afterRelaunch.owed(itemId: "ep")?.returnToMediaTimeMs, 12_000)
        XCTAssertNil(afterRelaunch.owed(itemId: "another"))
    }

    func testKeepingForRecordingSurvivesALaunchAndClearingForgetsIt() throws {
        let defaults = isolatedDefaults()
        let places = ReviewReturnPlaces(defaults: defaults)
        places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
        places.keepForRecording(itemId: "ep")
        XCTAssertEqual(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep")?.keptForRecording, true)
        places.clear(itemId: "ep")
        XCTAssertNil(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep"))
        XCTAssertNil(defaults.data(forKey: "spokenmargins.reviewReturnPlaces"), "nothing left behind")
    }

    func testRemovingAllForgetsEveryItemsPlace() throws {
        let defaults = isolatedDefaults()
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

    func testKeepingAnItemThatOwesNothingChangesNothing() {
        let defaults = isolatedDefaults()
        let places = ReviewReturnPlaces(defaults: defaults)
        places.keepForRecording(itemId: "ep")
        XCTAssertNil(places.owed(itemId: "ep"))
        XCTAssertNil(defaults.data(forKey: "spokenmargins.reviewReturnPlaces"))
    }

    func testAnotherReviewOfTheSameItemReplacesThePlace() throws {
        let places = ReviewReturnPlaces(defaults: isolatedDefaults())
        places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 12_000))))
        places.keepForRecording(itemId: "ep")
        places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 3_000))))
        XCTAssertEqual(places.owed(itemId: "ep")?.returnToMediaTimeMs, 3_000)
        XCTAssertEqual(places.owed(itemId: "ep")?.keptForRecording, false)
    }

    func testGarbageInTheStoreIsIgnored() throws {
        let defaults = isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "spokenmargins.reviewReturnPlaces")
        let places = ReviewReturnPlaces(defaults: defaults)
        XCTAssertNil(places.owed(itemId: "ep"))
        places.owe(try XCTUnwrap(ReviewReturnPlace(sequence: review())))
        XCTAssertEqual(places.owed(itemId: "ep")?.returnToMediaTimeMs, 12_000)
    }
}
