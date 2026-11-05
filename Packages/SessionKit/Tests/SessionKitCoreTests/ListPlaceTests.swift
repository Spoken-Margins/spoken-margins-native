import XCTest
@testable import SessionKit

/// #1990: the Library holds its place when rows above come and go. The numbers in the first test are the ones the lane
/// measured when this failed (report pr3328-r41877060518): 42 rows, then 43 with the queue's entry 68 pt tall.
final class ListPlaceTests: XCTestCase {
    private let row = 52.0

    /// Rows `first...last` of a list, each `row` tall, the first of them starting at `top`.
    private func rows(_ first: Int, _ last: Int, startingAt top: Double) -> [ListPlace.VisibleRow] {
        (first...last).map { index in
            let rowTop = top + Double(index - first) * row
            return .init(index: index, top: rowTop, bottom: rowTop + row)
        }
    }

    func testTheSameRowIsFoundWhetherOrNotTheListHasTakenTheChange() throws {
        let offset = 1240.67
        let place = try XCTUnwrap(ListPlace.reading(
            visibleRows: rows(20, 35, startingAt: 1300), rowCount: 42, offset: offset,
            viewTop: offset + 116, viewBottom: offset + 760))
        // The last row wholly above 2000.67 is row 32, whose top is at 1924.
        XCTAssertEqual(place.rowsFromEnd, 10)
        XCTAssertEqual(place.rowTop, 1924 - offset, accuracy: 0.001)

        // Not taken yet: the same row, and the offset stays as it is.
        XCTAssertEqual(place.rowIndex(inListOf: 42), 32)
        XCTAssertEqual(place.offset(keepingRowAt: 1924, lowest: -116, highest: 2000), offset, accuracy: 0.001)
        // Taken: the row is one further along and 68 pt down, and the offset follows it.
        XCTAssertEqual(place.rowIndex(inListOf: 43), 33)
        XCTAssertEqual(place.offset(keepingRowAt: 1924 + 68, lowest: -116, highest: 2000), offset + 68, accuracy: 0.001)
        // The entry goes again: back where it was.
        XCTAssertEqual(place.rowIndex(inListOf: 42), 32)
    }

    /// The list corrects its own estimates as it goes, so the row can land anywhere; the place follows the row.
    func testTheOffsetFollowsTheRowWhereverItLands() throws {
        let place = ListPlace(rowsFromEnd: 3, rowTop: 700)
        XCTAssertEqual(place.offset(keepingRowAt: 1940, lowest: -116, highest: 2000), 1240)
        XCTAssertEqual(place.offset(keepingRowAt: 1924, lowest: -116, highest: 2000), 1224)
    }

    func testTheOffsetStaysBetweenTheEndsOfTheList() {
        let place = ListPlace(rowsFromEnd: 1, rowTop: 700)
        XCTAssertEqual(place.offset(keepingRowAt: 100, lowest: -116, highest: 2000), -116)
        XCTAssertEqual(place.offset(keepingRowAt: 4000, lowest: -116, highest: 2000), 2000)
        // A list shorter than the screen has only the one place.
        XCTAssertEqual(place.offset(keepingRowAt: 4000, lowest: -116, highest: -300), -116)
    }

    func testAtTheTopOfTheListThereIsNoPlaceToKeep() {
        XCTAssertNil(ListPlace.reading(visibleRows: rows(0, 12, startingAt: 0), rowCount: 42, offset: -116,
                                       viewTop: 0, viewBottom: 644))
        XCTAssertNil(ListPlace.reading(visibleRows: rows(0, 12, startingAt: 0), rowCount: 42, offset: -115,
                                       viewTop: 1, viewBottom: 645))
        XCTAssertNotNil(ListPlace.reading(visibleRows: rows(0, 12, startingAt: 0), rowCount: 42, offset: -114,
                                          viewTop: 2, viewBottom: 646))
    }

    func testAListWithNoRowOnScreenHasNoPlace() {
        XCTAssertNil(ListPlace.reading(visibleRows: [], rowCount: 42, offset: 500, viewTop: 616, viewBottom: 1260))
    }

    /// A row taller than the screen is never whole, and it is still the one the listener is looking at.
    func testWithNoWholeRowTheLastPartlyOnScreenIsKept() throws {
        let tall = [ListPlace.VisibleRow(index: 4, top: 0, bottom: 700), .init(index: 5, top: 700, bottom: 1500)]
        let place = try XCTUnwrap(ListPlace.reading(visibleRows: tall, rowCount: 10, offset: 300, viewTop: 416, viewBottom: 1060))
        XCTAssertEqual(place.rowsFromEnd, 5)
        XCTAssertEqual(place.rowTop, 400)
    }

    /// A cell still on screen for a row the list no longer has can't be the one kept.
    func testACellPastTheEndOfTheListIsNotKept() throws {
        let place = try XCTUnwrap(ListPlace.reading(visibleRows: rows(38, 44, startingAt: 2000), rowCount: 42, offset: 1900,
                                                    viewTop: 2016, viewBottom: 2600))
        XCTAssertEqual(place.rowsFromEnd, 1) // row 41
    }

    func testAListTooShortForTheRowHasNoIndex() {
        let place = ListPlace(rowsFromEnd: 10, rowTop: 0)
        XCTAssertEqual(place.rowIndex(inListOf: 10), 0)
        XCTAssertNil(place.rowIndex(inListOf: 9))
    }
}
