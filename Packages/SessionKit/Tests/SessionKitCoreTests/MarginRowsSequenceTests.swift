import XCTest
@testable import SessionKit

/// No read of the Margins list that ran off the main thread publishes over a newer change (#2505, audit on #2747).
final class MarginRowsSequenceTests: XCTestCase {
    // The audit's case: the Margins tab's full read is running when Siri or a headphone double-press saves a Margin.
    func testAFullReadThatBeganBeforeAOneItemSaveReadsAgainInsteadOfPublishing() {
        var sequence = MarginRowsSequence()
        let full = sequence.beginRead(.all)
        let save = sequence.beginRead(.item("a"))
        XCTAssertEqual(sequence.finish(save), .publish, "the new Margin appears")
        XCTAssertEqual(sequence.finish(full), .rerun, "the older full read would hide the new Margin")
        let again = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(again), .publish)
    }

    func testAFullReadThatBeganBeforeAStarOrARemovedItemReadsAgain() {
        for change in [MarginRowsSequence.Scope.item("a"), .all] {
            var sequence = MarginRowsSequence()
            let full = sequence.beginRead(.all)
            sequence.noteChange(change)
            XCTAssertEqual(sequence.finish(full), .rerun, "\(change)")
        }
    }

    func testAOneItemReadThatBeganBeforeAStarOnTheSameItemReadsAgain() {
        var sequence = MarginRowsSequence()
        let save = sequence.beginRead(.item("a"))
        sequence.noteChange(.item("a"))
        XCTAssertEqual(sequence.finish(save), .rerun)
        let other = sequence.beginRead(.item("b"))
        sequence.noteChange(.item("a"))
        XCTAssertEqual(sequence.finish(other), .publish, "another item's star doesn't touch b's rows")
        let unknown = sequence.beginRead(.item("b"))
        sequence.noteChange(.all)
        XCTAssertEqual(sequence.finish(unknown), .rerun, "a change whose item isn't known may touch any item")
    }

    func testAOneItemReadThatBeganBeforeTheFullReadIsAlreadyInsideIt() {
        var sequence = MarginRowsSequence()
        let save = sequence.beginRead(.item("a"))
        let full = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(save), .publish)
        XCTAssertEqual(sequence.finish(full), .publish, "its rows began after the save's, so they hold it")
    }

    func testANewerReadOfTheSameScopeOrANewerFullListDropsAnOlderRead() {
        var sequence = MarginRowsSequence()
        let first = sequence.beginRead(.all)
        let second = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(second), .publish)
        XCTAssertEqual(sequence.finish(first), .drop)

        let olderSave = sequence.beginRead(.item("a"))
        let newerSave = sequence.beginRead(.item("a"))
        XCTAssertEqual(sequence.finish(newerSave), .publish)
        XCTAssertEqual(sequence.finish(olderSave), .drop)

        let late = sequence.beginRead(.item("a"))
        let full = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(full), .publish)
        XCTAssertEqual(sequence.finish(late), .drop, "the full list read after it holds a's rows")

        let beforeRebuild = sequence.beginRead(.all)
        let itemBeforeRebuild = sequence.beginRead(.item("b"))
        sequence.noteRebuild()
        XCTAssertEqual(sequence.finish(beforeRebuild), .drop)
        XCTAssertEqual(sequence.finish(itemBeforeRebuild), .drop)
    }

    func testAReadWithNothingNewerPublishes() {
        var sequence = MarginRowsSequence()
        sequence.noteChange(.item("a"))
        sequence.noteRebuild()
        let full = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(full), .publish)
        let item = sequence.beginRead(.item("a"))
        XCTAssertEqual(sequence.finish(item), .publish)
    }

    // #2766: an awaited refresh that was dropped must not return before the newer read that superseded it is done.
    func testADroppedReadWaitsOnlyForANewerReadOfItsScopeThatHasNotEnded() {
        var sequence = MarginRowsSequence()
        let older = sequence.beginRead(.item("a"))
        XCTAssertFalse(sequence.isWaitingOnNewerRead(older), "nothing newer began")
        let newer = sequence.beginRead(.item("a"))
        XCTAssertTrue(sequence.isWaitingOnNewerRead(older))
        let otherItem = sequence.beginRead(.item("b"))
        XCTAssertFalse(sequence.isWaitingOnNewerRead(otherItem), "a's read isn't b's newer read")
        XCTAssertEqual(sequence.finish(newer), .publish)
        XCTAssertEqual(sequence.finish(older), .drop)
        XCTAssertTrue(sequence.isWaitingOnNewerRead(older), "the newer read published but its caller hasn't finished")
        sequence.end(newer)
        XCTAssertFalse(sequence.isWaitingOnNewerRead(older))
    }

    func testAFullReadDroppedByANewerFullReadWaitsForIt() {
        var sequence = MarginRowsSequence()
        let first = sequence.beginRead(.all)
        let second = sequence.beginRead(.all)
        XCTAssertTrue(sequence.isWaitingOnNewerRead(first))
        XCTAssertFalse(sequence.isWaitingOnNewerRead(second))
        XCTAssertEqual(sequence.finish(second), .publish)
        sequence.end(second)
        XCTAssertFalse(sequence.isWaitingOnNewerRead(first))
    }

    func testAReadDroppedByAPublishedFullListHasNothingToWaitFor() {
        var sequence = MarginRowsSequence()
        let late = sequence.beginRead(.item("a"))
        sequence.noteRebuild()
        XCTAssertEqual(sequence.finish(late), .drop)
        XCTAssertFalse(sequence.isWaitingOnNewerRead(late), "the rebuilt list is already on screen")
    }

    // #2768, the order the hosted Mac hit: the Margins tab's full read is in flight, Siri saves a Margin, and the
    // save's own background one-item read begins after the caller's awaited one. The awaited read lands first and is
    // dropped; it must wait for the background read to publish, and the older full read must read again.
    func testAnAwaitedSaveReadDroppedByTheSavesOwnBackgroundReadWaitsForItAndTheFullReadReadsAgain() {
        var sequence = MarginRowsSequence()
        let full = sequence.beginRead(.all)
        let awaited = sequence.beginRead(.item("a"))
        let background = sequence.beginRead(.item("a"))
        XCTAssertEqual(sequence.finish(awaited), .drop)
        XCTAssertTrue(sequence.isWaitingOnNewerRead(awaited), "returning now would show rows without the new Margin")
        XCTAssertEqual(sequence.finish(background), .publish)
        XCTAssertTrue(sequence.isWaitingOnNewerRead(awaited), "published, but its caller hasn't applied the rows")
        sequence.end(background)
        XCTAssertFalse(sequence.isWaitingOnNewerRead(awaited), "the new Margin is on the list")
        sequence.end(awaited)
        XCTAssertEqual(sequence.finish(full), .rerun, "its rows predate the save and would hide it")
        let again = sequence.beginRead(.all)
        XCTAssertEqual(sequence.finish(again), .publish)
    }
}
