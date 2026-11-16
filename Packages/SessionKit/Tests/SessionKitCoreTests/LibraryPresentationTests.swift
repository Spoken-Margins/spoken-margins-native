import XCTest
@testable import SessionKit

final class LibraryPresentationTests: XCTestCase {
    func testContinueItemPrefersTheActiveUnfinishedItem() throws {
        let active = libraryRow(
            id: "active",
            title: "Active",
            progress: 0,
            lastListenedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = libraryRow(
            id: "newer",
            title: "Newer",
            progress: 45,
            lastListenedAt: Date(timeIntervalSince1970: 100)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(in: [newer, active], activeItemId: active.id)
        )

        XCTAssertEqual(selected.id, active.id)
    }

    func testContinueItemFallsBackToMostRecentlyListenedUnfinishedItem() throws {
        let older = libraryRow(
            id: "older",
            title: "Older",
            progress: 20,
            lastListenedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = libraryRow(
            id: "newer",
            title: "Newer",
            progress: 30,
            lastListenedAt: Date(timeIntervalSince1970: 20)
        )
        let completed = libraryRow(
            id: "completed",
            title: "Completed",
            progress: 100,
            lastListenedAt: Date(timeIntervalSince1970: 30)
        )
        let unplayed = libraryRow(
            id: "unplayed",
            title: "Unplayed",
            progress: 0,
            lastListenedAt: Date(timeIntervalSince1970: 40)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(
                in: [older, completed, unplayed, newer],
                activeItemId: "missing"
            )
        )

        XCTAssertEqual(selected.id, newer.id)
    }

    func testContinueItemUsesIdentifierAsStableTieBreaker() throws {
        let sameDate = Date(timeIntervalSince1970: 100)
        let zulu = libraryRow(id: "zulu", title: "Zulu", progress: 10, lastListenedAt: sameDate)
        let alpha = libraryRow(id: "alpha", title: "Alpha", progress: 10, lastListenedAt: sameDate)

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(in: [zulu, alpha], activeItemId: nil)
        )

        XCTAssertEqual(selected.id, alpha.id)
    }

    func testContinueItemDoesNotSuggestNinetyNinePercentItems() throws {
        let activeNearComplete = libraryRow(
            id: "active-near-complete",
            title: "Near complete",
            progress: 99,
            lastListenedAt: Date(timeIntervalSince1970: 30)
        )
        let eligible = libraryRow(
            id: "eligible",
            title: "Eligible",
            progress: 98,
            lastListenedAt: Date(timeIntervalSince1970: 20)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(
                in: [activeNearComplete, eligible],
                activeItemId: activeNearComplete.id
            )
        )

        XCTAssertEqual(selected.id, eligible.id)
        XCTAssertNil(
            LibraryPresentation.continueItem(
                in: [activeNearComplete],
                activeItemId: activeNearComplete.id
            )
        )
    }

    func testMarkedCompleteItemIsExcludedEvenWhenActiveSessionStillHasProgress() {
        let completed = LibraryItemRow(id: "done", title: "Done", status: "Ready", canDelete: true, hasContinuationSession: true, continuationProgressPercent: 35, isCompleted: true)
        XCTAssertNil(LibraryPresentation.continueItem(in: [completed], activeItemId: completed.id))
    }

    func testContinueItemIsNilWithoutAnEligibleUnfinishedItem() {
        let completed = libraryRow(id: "completed", title: "Completed", progress: 100)
        let unplayed = libraryRow(id: "unplayed", title: "Unplayed", progress: 0)
        let noSession = libraryRow(id: "none", title: "No Session", progress: nil)

        XCTAssertNil(
            LibraryPresentation.continueItem(
                in: [completed, unplayed, noSession],
                activeItemId: completed.id
            )
        )
        XCTAssertNil(LibraryPresentation.continueItem(in: [], activeItemId: nil))
    }

    private func libraryRow(
        id: String,
        title: String,
        progress: Int?,
        lastListenedAt: Date? = nil
    ) -> LibraryItemRow {
        LibraryItemRow(
            id: id,
            title: title,
            status: "Ready",
            canDelete: true,
            hasContinuationSession: progress != nil,
            continuationProgressPercent: progress,
            lastListenedAt: lastListenedAt
        )
    }
}
