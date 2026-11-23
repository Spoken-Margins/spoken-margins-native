import XCTest
@testable import SessionKit

/// #4274: which Quick Folder files Following may list once nothing imports them by itself. A burst of new files past the
/// newest eight must stay reachable, and a long-lived folder's old files must not come back as new.
final class QuickFolderListingTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_000_000)

    /// `count` files, `f00` the newest, each one minute older than the one before, the newest `offset` seconds from `since`.
    private func files(_ count: Int, newestAt offset: TimeInterval) -> [QuickAccessFileCandidate] {
        (0..<count).map { index in
            let id = String(format: "f%02d", index)
            return QuickAccessFileCandidate(id: id, name: id, relativePath: id, modifiedAt: since.addingTimeInterval(offset - Double(index) * 60))
        }
    }

    private func newest(_ all: [QuickAccessFileCandidate]) -> [QuickAccessFileCandidate] {
        Array(all.prefix(QuickAccessFolderScanner.quickAddLimit))
    }

    private func described(_ candidates: [QuickAccessFileCandidate]) -> [QuickAccessFile] {
        candidates.map { QuickAccessFile(id: $0.id, name: $0.name, relativePath: $0.relativePath, modifiedAt: $0.modifiedAt, modifiedAtDescription: "") }
    }

    // MARK: pool

    func testTwelveFilesAllAfterTheChosenDateAllComeBackNewestFirst() {
        let all = files(12, newestAt: 3_600)
        let pool = QuickFolderListing.pool(newest: newest(all), all: all, since: since)
        XCTAssertEqual(pool.map(\.id), all.map(\.id))
    }

    func testThreeHundredFilesAllBeforeTheChosenDateGiveOnlyTheNewestEight() {
        let all = files(300, newestAt: -60)
        let pool = QuickFolderListing.pool(newest: newest(all), all: all, since: since)
        XCTAssertEqual(pool.map(\.id), newest(all).map(\.id))
    }

    func testNoChosenDateGivesTheNewestEightUnchanged() {
        let all = files(12, newestAt: 3_600)
        let pool = QuickFolderListing.pool(newest: newest(all), all: all, since: nil)
        XCTAssertEqual(pool.map(\.id), newest(all).map(\.id))
    }

    func testAFileInBothListsAppearsOnce() {
        let all = files(3, newestAt: 3_600)
        let pool = QuickFolderListing.pool(newest: all, all: all, since: since)
        XCTAssertEqual(pool.map(\.id), ["f00", "f01", "f02"])
    }

    func testAFileModifiedExactlyAtTheChosenDateCounts() {
        let all = files(9, newestAt: 8 * 60) // f08 sits exactly on `since`
        let pool = QuickFolderListing.pool(newest: newest(all), all: all, since: since)
        XCTAssertEqual(pool.last?.id, "f08")
        XCTAssertEqual(pool.count, 9)
    }

    func testAMixedFolderKeepsOnlyTheNewFilesPastTheNewestEight() {
        // 10 new files (after `since`), then 20 old ones: the 10 new come back, and no old file past the newest eight.
        let new = files(10, newestAt: 36_000)
        let old = files(20, newestAt: -60).map {
            QuickAccessFileCandidate(id: "old-" + $0.id, name: $0.name, relativePath: "old-" + $0.relativePath, modifiedAt: $0.modifiedAt)
        }
        let all = new + old
        let pool = QuickFolderListing.pool(newest: newest(all), all: all, since: since)
        XCTAssertEqual(pool.map(\.id), new.map(\.id))
    }

    func testTiesAreOrderedById() {
        let date = since.addingTimeInterval(60)
        let all = ["c", "a", "b"].map { QuickAccessFileCandidate(id: $0, name: $0, relativePath: $0, modifiedAt: date) }
        let pool = QuickFolderListing.pool(newest: [], all: all, since: since)
        XCTAssertEqual(pool.map(\.id), ["a", "b", "c"])
    }

    func testAnEmptyFolderGivesNothing() {
        XCTAssertEqual(QuickFolderListing.pool(newest: [], all: [], since: since).count, 0)
        XCTAssertEqual(QuickFolderListing.listed([], dismissedKeys: []).count, 0)
    }

    // MARK: listed

    func testWithTheNewestEightDismissedTheNextFourAreListed() {
        let all = files(12, newestAt: 3_600)
        let pool = described(QuickFolderListing.pool(newest: newest(all), all: all, since: since))
        let dismissed = Set(pool.prefix(8).map(\.dismissalKey))
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: dismissed).map(\.id), ["f08", "f09", "f10", "f11"])
    }

    func testWithNothingDismissedEightAreListed() {
        let all = files(12, newestAt: 3_600)
        let pool = described(QuickFolderListing.pool(newest: newest(all), all: all, since: since))
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: []).map(\.id), Array(all.prefix(8)).map(\.id))
    }

    func testAFileDismissedAtAnEarlierModifiedTimeIsListedAgainOnceChanged() {
        // The dismissal key carries the modified time, so an edited file is new again, as Following has always treated it.
        let all = files(1, newestAt: 60)
        let pool = described(all)
        let staleKey = "f00|\(Int(since.timeIntervalSince1970))"
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: [staleKey]).map(\.id), ["f00"])
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: [pool[0].dismissalKey]).count, 0)
    }

    func testANonPositiveLimitListsNothing() {
        let pool = described(files(3, newestAt: 60))
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: [], limit: 0).count, 0)
        XCTAssertEqual(QuickFolderListing.listed(pool, dismissedKeys: [], limit: -1).count, 0)
    }
}
