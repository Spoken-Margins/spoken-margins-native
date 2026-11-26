import SessionKit
import XCTest

/// A Following row's ▶ spinner and its "Adding…" come from which action started the fetch, not from the fetch alone (#5328).
final class FollowedEntryImportsTests: XCTestCase {
    private func status(_ imports: FollowedEntryImports, playEntryID: String?, newestEntryID: String?) -> FollowingRowStatus? {
        FollowingRowStatus.resolve(
            isAdding: imports.isAdding(newestEntryID), isPlayStarting: imports.isPlayStarting(playEntryID), isNewestInLibrary: false)
    }

    func testASwipeAddOnTheEpisodePlayWouldPlayShowsAddingAndLeavesPlayAlone() {
        var imports = FollowedEntryImports()
        XCTAssertTrue(imports.begin("ep1", play: false))
        // ▶ plays the episode the row previews, so both ids are the same: the case the old shared set got wrong.
        XCTAssertEqual(status(imports, playEntryID: "ep1", newestEntryID: "ep1"), .adding)
        XCTAssertFalse(imports.isPlayStarting("ep1"))
    }

    func testAPlayTapShowsItsSpinnerAndNoAdding() {
        var imports = FollowedEntryImports()
        XCTAssertTrue(imports.begin("ep1", play: true))
        XCTAssertTrue(imports.isPlayStarting("ep1"))
        XCTAssertNil(status(imports, playEntryID: "ep1", newestEntryID: "ep1"))
    }

    func testASecondRequestRidesOnTheRunningFetch() {
        var imports = FollowedEntryImports()
        XCTAssertTrue(imports.begin("ep1", play: false))
        XCTAssertFalse(imports.begin("ep1", play: false))
        XCTAssertFalse(imports.begin("ep1", play: true), "a ▶ during an Add joins it instead of fetching twice")
        XCTAssertEqual(imports.importing, ["ep1"])
    }

    func testAPlayTapDuringAnAddJoinsItOnceAndHandsBackItsToken() {
        var request = CurrentRequest()
        var imports = FollowedEntryImports()
        imports.begin("ep1", play: false)
        XCTAssertTrue(imports.canJoinForPlay("ep1"))
        let token = request.begin()
        imports.joinForPlay("ep1", token: token)
        XCTAssertTrue(imports.isPlayStarting("ep1"))
        XCTAssertNil(status(imports, playEntryID: "ep1", newestEntryID: "ep1"), "the ▶ spinner replaces Adding…")
        XCTAssertFalse(imports.canJoinForPlay("ep1"), "▶ is waiting already, so a second tap doesn't join again")
        XCTAssertEqual(imports.takeJoinedPlay("ep1"), token)
        XCTAssertNil(imports.takeJoinedPlay("ep1"), "the join plays once")
        XCTAssertTrue(imports.isPlayStarting("ep1"), "▶ keeps its spinner until the fetch ends")
        XCTAssertNil(imports.end("ep1"))
        XCTAssertFalse(imports.contains("ep1"))
        XCTAssertFalse(imports.isPlayStarting("ep1"))
    }

    func testAFetchStartedByPlayHandsBackNoJoinToken() {
        var imports = FollowedEntryImports()
        imports.begin("ep1", play: true)
        XCTAssertFalse(imports.canJoinForPlay("ep1"))
        XCTAssertNil(imports.end("ep1"), "the fetch plays the item itself")
    }

    func testNothingRunningIsNeitherAddingNorStarting() {
        let imports = FollowedEntryImports()
        XCTAssertFalse(imports.isAdding("ep1"))
        XCTAssertFalse(imports.isPlayStarting("ep1"))
        XCTAssertFalse(imports.isAdding(nil))
        XCTAssertFalse(imports.isPlayStarting(nil))
        XCTAssertFalse(imports.canJoinForPlay("ep1"))
    }

    func testAnAddOfOneEpisodeDoesNotTouchAnother() {
        var imports = FollowedEntryImports()
        imports.begin("ep2", play: false)
        XCTAssertFalse(imports.isAdding("ep1"))
        XCTAssertNil(status(imports, playEntryID: "ep1", newestEntryID: "ep1"))
    }
}
