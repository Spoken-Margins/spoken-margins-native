import Foundation
import XCTest
@testable import SessionKit

/// #4337: a sheet or cover built twice while it is open reached the owner's phone as #2831, #4091 (twice) and #3891.
/// Each test walks the ledger through the appear and disappear calls the app makes, and names what the rule must say.
final class PresentationLedgerTests: XCTestCase {
    private let place = "PlaybackScreen:229"

    func testAPresentationThatAppearsOnceAndGoesIsNotARebuild() {
        var ledger = PresentationLedger()
        let build = UUID()

        XCTAssertNil(ledger.appeared(place: place, instance: build, at: 0))
        ledger.disappeared(instance: build, at: 5)

        XCTAssertEqual(ledger.rebuildCount, 0)
        XCTAssertEqual(ledger.summaryText, "rebuilds=0")
    }

    func testASecondBuildThatAppearsWhileTheFirstIsShowingIsARebuild() throws {
        var ledger = PresentationLedger()
        ledger.appeared(place: place, instance: UUID(), at: 0)

        let rebuild = try XCTUnwrap(ledger.appeared(place: place, instance: UUID(), at: 3))

        XCTAssertEqual(rebuild.reason, .whileShowing)
        XCTAssertEqual(rebuild.place, place)
        XCTAssertEqual(ledger.rebuildCount, 1)
    }

    func testASecondBuildWithinASecondOfTheFirstGoingIsARebuild() throws {
        var ledger = PresentationLedger()
        let first = UUID()
        ledger.appeared(place: place, instance: first, at: 10)
        ledger.disappeared(instance: first, at: 12)

        let rebuild = try XCTUnwrap(ledger.appeared(place: place, instance: UUID(), at: 12.4))

        XCTAssertEqual(rebuild.reason, .afterDismissal)
    }

    func testTheWindowIsOneSecondAndALaterBuildIsTheListenerOpeningItAgain() throws {
        var ledger = PresentationLedger()
        let first = UUID()
        ledger.appeared(place: place, instance: first, at: 0)
        ledger.disappeared(instance: first, at: 2)

        XCTAssertNotNil(ledger.appeared(place: place, instance: UUID(), at: 3), "exactly one second after is still inside the window")

        var later = PresentationLedger()
        later.appeared(place: place, instance: first, at: 0)
        later.disappeared(instance: first, at: 2)
        XCTAssertNil(later.appeared(place: place, instance: UUID(), at: 3.01))
        XCTAssertEqual(later.rebuildCount, 0)
    }

    func testTheSameBuildShowingAgainIsNotARebuild() {
        // A cover under another cover disappears and appears again as the one above it comes and goes: same build.
        var ledger = PresentationLedger()
        let build = UUID()
        ledger.appeared(place: place, instance: build, at: 0)
        ledger.disappeared(instance: build, at: 1)

        XCTAssertNil(ledger.appeared(place: place, instance: build, at: 1.1))
        XCTAssertNil(ledger.appeared(place: place, instance: build, at: 1.2), "an appear that repeats while showing says nothing new")
        XCTAssertEqual(ledger.rebuildCount, 0)
    }

    func testAnotherItemInTheSamePlaceIsNotARebuild() {
        var ledger = PresentationLedger()
        let first = UUID()
        ledger.appeared(place: place, item: "margin-a", instance: first, at: 0)

        XCTAssertNil(ledger.appeared(place: place, item: "margin-b", instance: UUID(), at: 0.1), "another Margin opening is another presentation")
        ledger.disappeared(instance: first, at: 0.2)
        XCTAssertNil(ledger.appeared(place: place, item: "margin-c", instance: UUID(), at: 0.3))
        XCTAssertEqual(ledger.rebuildCount, 0)
    }

    func testTheSameItemInTheSamePlaceIsARebuildEvenWithAnItem() throws {
        var ledger = PresentationLedger()
        ledger.appeared(place: place, item: "margin-a", instance: UUID(), at: 0)

        let rebuild = try XCTUnwrap(ledger.appeared(place: place, item: "margin-a", instance: UUID(), at: 0.5))

        XCTAssertEqual(rebuild.item, "margin-a")
    }

    func testAnotherPlaceWithTheSameItemIsNotARebuild() {
        var ledger = PresentationLedger()
        ledger.appeared(place: "PlaybackNowView:74", item: "margin-a", instance: UUID(), at: 0)

        XCTAssertNil(ledger.appeared(place: "ExperienceMarginsScreen:143", item: "margin-a", instance: UUID(), at: 0.1))
    }

    func testAPresentationWithNoItemIsNotTheSameAsOneWithAnItem() {
        var ledger = PresentationLedger()
        ledger.appeared(place: place, item: nil, instance: UUID(), at: 0)

        XCTAssertNil(ledger.appeared(place: place, item: "a", instance: UUID(), at: 0.1))
    }

    func testAGoneBuildThatNeverAppearedIsIgnored() {
        var ledger = PresentationLedger()

        ledger.disappeared(instance: UUID(), at: 0)

        XCTAssertNil(ledger.appeared(place: place, instance: UUID(), at: 0.1))
    }

    func testTheSummaryNamesCountsAndTheWorstPlacesFirst() {
        var ledger = PresentationLedger()
        for step in 0..<3 { ledger.appeared(place: "A:1", instance: UUID(), at: Double(step)) }   // two while showing
        for step in 0..<2 { ledger.appeared(place: "B:2", instance: UUID(), at: Double(step)) }   // one while showing
        let gone = UUID()
        ledger.appeared(place: "C:3", instance: gone, at: 0)
        ledger.disappeared(instance: gone, at: 1)
        ledger.appeared(place: "C:3", instance: UUID(), at: 1.5)                                  // one after dismissal

        XCTAssertEqual(ledger.summaryText, "rebuilds=4 whileShowing=3 afterDismissal=1 places=A:1x2,B:2x1,C:3x1")
    }

    func testTheSummaryCarriesNoItemAndOnlyTheFivePlacesThatRebuiltMost() {
        var ledger = PresentationLedger()
        for place in 0..<7 {
            ledger.appeared(place: "P:\(place)", item: "title-the-listener-typed", instance: UUID(), at: 0)
            ledger.appeared(place: "P:\(place)", item: "title-the-listener-typed", instance: UUID(), at: 0)
        }

        XCTAssertFalse(ledger.summaryText.contains("title"))
        XCTAssertEqual(ledger.summaryText.components(separatedBy: ",").count, 5)
        XCTAssertEqual(ledger.rebuildCount, 7)
    }

    func testTheKeptRebuildsAreBoundedAndTheCountsAreNot() {
        var ledger = PresentationLedger()
        let total = PresentationLedger.keptRebuilds + 15
        ledger.appeared(place: place, instance: UUID(), at: 0)
        for _ in 0..<total { ledger.appeared(place: place, instance: UUID(), at: 0) }

        XCTAssertEqual(ledger.rebuildCount, total)
        XCTAssertEqual(ledger.recent.count, PresentationLedger.keptRebuilds)
    }

    func testARebuildReadsAsTheScreenAndWhatHappened() throws {
        var ledger = PresentationLedger()
        ledger.appeared(place: place, item: "margin-a", instance: UUID(), at: 0)
        let rebuild = try XCTUnwrap(ledger.appeared(place: place, item: "margin-a", instance: UUID(), at: 0))

        XCTAssertEqual(rebuild.description, "PlaybackScreen:229 for margin-a: built a second time while the first was still showing")
    }

    func testBuildsThatWentLongAgoAreForgotten() {
        var ledger = PresentationLedger()
        for step in 0..<50 {
            let build = UUID()
            ledger.appeared(place: "P:\(step)", item: "item-\(step)", instance: build, at: Double(step) * 10)
            ledger.disappeared(instance: build, at: Double(step) * 10 + 1)
        }
        ledger.appeared(place: "Q:1", instance: UUID(), at: 1000)

        XCTAssertEqual(ledger.rememberedGoneCount, 0)
        XCTAssertEqual(ledger.rebuildCount, 0)
    }

    func testTheSamePresentationInAnotherWindowIsNotARebuild() throws {
        // An iPad's two windows share one model, so each presents the Terms sheet when the model sets it.
        var ledger = PresentationLedger()
        ledger.appeared(place: "Gate1RootView:71", scene: "scene-a", instance: UUID(), at: 0)

        XCTAssertNil(ledger.appeared(place: "Gate1RootView:71", scene: "scene-b", instance: UUID(), at: 0.1))
        XCTAssertEqual(ledger.rebuildCount, 0)

        let rebuild = try XCTUnwrap(ledger.appeared(place: "Gate1RootView:71", scene: "scene-b", instance: UUID(), at: 0.2), "a second build in the same window still is")
        XCTAssertEqual(rebuild.reason, .whileShowing)
    }

    func testAWindowGoingAndTheSameSheetOpeningInAnotherIsNotARebuildAfterDismissal() {
        var ledger = PresentationLedger()
        let first = UUID()
        ledger.appeared(place: "Gate1RootView:86", scene: "scene-a", instance: first, at: 0)
        ledger.disappeared(instance: first, at: 1)

        XCTAssertNil(ledger.appeared(place: "Gate1RootView:86", scene: "scene-b", instance: UUID(), at: 1.2))
    }
}
