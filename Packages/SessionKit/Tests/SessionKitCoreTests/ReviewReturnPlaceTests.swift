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

    // MARK: #3626 — a Margin whose voice never starts, and a catch-up review

    /// The sequence once playback has reached its first Margin: the Margin has the floor, though no voice has started.
    private func reachingTheFirstMargin(_ sequence: MarginMomentSequence) throws -> MarginMomentSequence {
        var reached = sequence
        let first = try XCTUnwrap(sequence.unplayed.first)
        XCTAssertNotNil(reached.progressed(from: first.mediaTimeMs - 1_000, to: first.mediaTimeMs + 100))
        XCTAssertTrue(reached.hasReachedAMargin)
        return reached
    }

    func testNothingChangesBeforeAMarginIsReached() throws {
        let sequence = review(returnTo: 2_000, margins: [60_000, 200_000])
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: sequence))
        XCTAssertEqual(place.standing(whenReviewIs: sequence), .owed(place), "the first lead-in still owes the place")
        XCTAssertTrue(place.needsRestoring(from: sequence.startMediaTimeMs), "a relaunch during the first lead-in goes back")
    }

    /// The Margin's voice is unplayable, or iOS ends the app during the chime: `onVoiceStarted` never runs, but the Margin
    /// has had the floor, and the place is let go all the same.
    func testAMarginThatHasTheFloorReleasesThePlaceEvenIfItsVoiceNeverStarts() throws {
        let sequence = try reachingTheFirstMargin(review(returnTo: 2_000, margins: [60_000, 200_000]))
        XCTAssertTrue(sequence.isPlayingMargin)
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: review(returnTo: 2_000, margins: [60_000, 200_000])))
        XCTAssertEqual(place.standing(whenReviewIs: sequence), .released)
        XCTAssertTrue(place.needsRestoring(from: 90_000), "what a relaunch would have done to a listener who had played on")
    }

    func testAPlaceBetweenTwoMarginsIsNotRestoredOnceTheEpisodePassedIt() throws {
        // Margins at 1:00 and 3:20, the listener's place 1:40: the review pulls them back to catch up.
        let start = review(returnTo: 100_000, margins: [60_000, 200_000])
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: start))
        guard case .owed(let afterFirst) = place.standing(whenReviewIs: try reachingTheFirstMargin(start)) else {
            return XCTFail("the place is ahead of the first Margin, so it stays owed")
        }
        XCTAssertEqual(afterFirst.passedAMargin, true)
        XCTAssertEqual(afterFirst.returnToMediaTimeMs, 100_000)
        XCTAssertFalse(afterFirst.needsRestoring(from: 150_000), "the episode played on past the place: stays, as Stop would")
        XCTAssertFalse(afterFirst.needsRestoring(from: 100_000 + 5_000))
        XCTAssertTrue(afterFirst.needsRestoring(from: 80_000), "still catching up: goes back to the place")
        XCTAssertFalse(afterFirst.needsRestoring(from: 100_000 + ReviewReturnPlace.alreadyThereMs), "already there")
        XCTAssertFalse(afterFirst.needsRestoring(from: afterFirst.stretchEndMs + 1), "outside the stretch is the listener's own")
        XCTAssertFalse(afterFirst.needsRestoring(from: afterFirst.stretchStartMs - 1), "outside the stretch is the listener's own")
        XCTAssertTrue(place.needsRestoring(from: 150_000), "the note before a Margin is reached still goes back: the hop moved it")
    }

    func testTheNextMarginPastThePlaceReleasesTheCatchUpNote() throws {
        var sequence = review(returnTo: 100_000, margins: [60_000, 200_000])
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: sequence))
        sequence = try reachingTheFirstMargin(sequence)
        guard case .owed(let afterFirst) = place.standing(whenReviewIs: sequence) else { return XCTFail("still owed") }
        sequence.marginFinished(sourceAtMediaTimeMs: 61_000)
        XCTAssertEqual(afterFirst.standing(whenReviewIs: sequence), .owed(afterFirst), "between Margins nothing changes")
        XCTAssertNotNil(sequence.progressed(from: 199_000, to: 200_100))
        XCTAssertEqual(afterFirst.standing(whenReviewIs: sequence), .released, "the 3:20 Margin is past the place")
    }

    /// A note saved by an earlier build has no `passedAMargin`: it decodes, and keeps the rule it always had.
    func testANoteSavedByAnEarlierBuildStillDecodes() throws {
        let old = Data(#"{"itemId":"ep","returnToMediaTimeMs":12000,"stretchStartMs":0,"stretchEndMs":40000}"#.utf8)
        let place = try JSONDecoder().decode(ReviewReturnPlace.self, from: old)
        XCTAssertNil(place.passedAMargin)
        XCTAssertTrue(place.needsRestoring(from: 30_000))
        let again = try JSONDecoder().decode(ReviewReturnPlace.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(again, place)
    }

    func testAPassedMarginSurvivesALaunch() throws {
        let start = review(returnTo: 100_000, margins: [60_000, 200_000])
        let place = try XCTUnwrap(ReviewReturnPlace(sequence: start))
        guard case .owed(let passed) = place.standing(whenReviewIs: try reachingTheFirstMargin(start)) else { return XCTFail() }
        try withIsolatedDefaults { defaults in
            ReviewReturnPlaces(defaults: defaults).owe(passed)
            let reloaded = try XCTUnwrap(ReviewReturnPlaces(defaults: defaults).owed(itemId: "ep"))
            XCTAssertEqual(reloaded.passedAMargin, true)
            XCTAssertFalse(reloaded.needsRestoring(from: 150_000))
        }
    }
}
