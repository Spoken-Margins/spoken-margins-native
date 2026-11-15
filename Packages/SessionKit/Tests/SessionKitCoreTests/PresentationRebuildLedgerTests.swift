import Foundation
import XCTest
@testable import SessionKit

/// #4337: the rules that tell a screen built again while open from a screen the listener closed and opened, or one
/// SwiftUI showed again after a push inside it. Each case is the order of events SwiftUI sends for it.
final class PresentationRebuildLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let cover = "LiveSessionView.swift:202"

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testANewBuildThatAppearsWhileTheFirstStillShowsIsARebuild() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.built(token: 2, presentation: cover, item: nil)
        let rebuild = ledger.appeared(token: 2, at: at(5))
        ledger.disappeared(token: 1, at: at(5.1))
        XCTAssertEqual(rebuild, .init(presentation: cover, gapMs: 0))
    }

    /// The order the owner's phone showed for #4091: the old screen goes, the new one appears a moment later.
    func testANewBuildThatAppearsJustAfterTheFirstWentIsARebuild() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.built(token: 2, presentation: cover, item: nil)
        ledger.disappeared(token: 1, at: at(3))
        XCTAssertEqual(ledger.appeared(token: 2, at: at(3.4)), .init(presentation: cover, gapMs: 400))
        XCTAssertEqual(ledger.summary, "\(cover)×1")
    }

    func testClosingAndOpeningTheSameScreenAgainIsNotARebuild() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.disappeared(token: 1, at: at(10))
        ledger.built(token: 2, presentation: cover, item: nil)
        XCTAssertNil(ledger.appeared(token: 2, at: at(11.5)))
        XCTAssertEqual(ledger.summary, "none")
    }

    func testTheSameBuildShownAgainAfterAPushIsNotARebuild() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.disappeared(token: 1, at: at(2))
        XCTAssertNil(ledger.appeared(token: 1, at: at(2.2)))
        XCTAssertTrue(ledger.rebuilds.isEmpty)
    }

    func testABuildThatNeverAppearedDoesNotCount() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil) // built and dropped by SwiftUI, never shown
        ledger.built(token: 2, presentation: cover, item: nil)
        XCTAssertNil(ledger.appeared(token: 2, at: at(0)))
    }

    func testAnotherItemUnderTheSamePresentationIsANewScreen() {
        var ledger = PresentationRebuildLedger()
        let sheet = "PlaybackMarginsView.swift:66"
        ledger.built(token: 1, presentation: sheet, item: "margin-a")
        ledger.appeared(token: 1, at: at(0))
        ledger.built(token: 2, presentation: sheet, item: "margin-b")
        ledger.disappeared(token: 1, at: at(1))
        XCTAssertNil(ledger.appeared(token: 2, at: at(1.2)))
    }

    func testTheSameItemRebuiltUnderASheetIsARebuild() {
        var ledger = PresentationRebuildLedger()
        let sheet = "PlaybackMarginsView.swift:66"
        ledger.built(token: 1, presentation: sheet, item: "margin-a")
        ledger.appeared(token: 1, at: at(0))
        ledger.built(token: 2, presentation: sheet, item: "margin-a")
        ledger.disappeared(token: 1, at: at(1))
        XCTAssertNotNil(ledger.appeared(token: 2, at: at(1.2)))
    }

    func testTheGapAtTheWindowIsNotARebuild() {
        var ledger = PresentationRebuildLedger(window: 1.0)
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.disappeared(token: 1, at: at(1))
        ledger.built(token: 2, presentation: cover, item: nil)
        XCTAssertNil(ledger.appeared(token: 2, at: at(2.0)))
    }

    func testAReleasedBuildIsStillComparedWhenItWasTheLastShown() {
        var ledger = PresentationRebuildLedger()
        ledger.built(token: 1, presentation: cover, item: nil)
        ledger.appeared(token: 1, at: at(0))
        ledger.disappeared(token: 1, at: at(1))
        ledger.released(token: 1) // the old screen object is gone before the new one appears
        ledger.built(token: 2, presentation: cover, item: nil)
        XCTAssertNotNil(ledger.appeared(token: 2, at: at(1.3)))
    }

    func testTheSummaryListsTheMostRebuiltFirst() {
        var ledger = PresentationRebuildLedger()
        var token = 0
        func rebuildOnce(_ presentation: String, from second: Double) {
            token += 1
            ledger.built(token: token, presentation: presentation, item: nil)
            ledger.appeared(token: token, at: at(second))
        }
        rebuildOnce("A.swift:1", from: 0)
        rebuildOnce("A.swift:1", from: 1)
        rebuildOnce("A.swift:1", from: 2)
        rebuildOnce("B.swift:9", from: 10)
        rebuildOnce("B.swift:9", from: 11)
        XCTAssertEqual(ledger.summary, "A.swift:1×2, B.swift:9×1")
    }
}
