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
}
