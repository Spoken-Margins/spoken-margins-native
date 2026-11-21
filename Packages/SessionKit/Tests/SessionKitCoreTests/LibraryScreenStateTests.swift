import XCTest
@testable import SessionKit

/// #1969: a build that can't open the Library says so, instead of the empty "Your Library is ready".
final class LibraryScreenStateTests: XCTestCase {
    private let error = "This build could not open your existing library. This attempt did not reset it. Do not use Reset Library or delete the app; install a compatible build and try again. Details: persistence_failed:schema is newer"

    func testAnAccessErrorOutranksTheEmptyState() {
        let state = LibraryScreenState.resolve(accessError: error, itemCount: 0, isCaughtUp: false, visibleCount: 0)
        XCTAssertEqual(state, .cannotOpen(LibraryAccessNote(accessError: error)))
        XCTAssertNotEqual(state, .empty, "Without the fix the screen reads 'Your Library is ready'")
        XCTAssertFalse(state.allowsAddingContent)
    }

    func testTheNoteSaysTheLibraryIsSafeAndNotToDeleteTheApp() {
        XCTAssertEqual(LibraryAccessNote.title, "Your Library is safe, but this version can't open it.")
        XCTAssertEqual(LibraryAccessNote.message, "Don't delete the app. Update Spoken Margins, then reopen it.")
    }

    func testTheTechnicalReasonGoesUnderDetails() {
        XCTAssertEqual(LibraryAccessNote(accessError: error).detail, "persistence_failed:schema is newer")
        XCTAssertEqual(LibraryAccessNote(accessError: "disk error").detail, "disk error", "No marker: the whole text is the detail")
    }

    func testWithoutAnErrorTheOldStatesHold() {
        func state(items: Int, caughtUp: Bool = false, visible: Int) -> LibraryScreenState {
            .resolve(accessError: nil, itemCount: items, isCaughtUp: caughtUp, visibleCount: visible)
        }
        XCTAssertEqual(state(items: 0, visible: 0), .empty)
        XCTAssertEqual(state(items: 3, caughtUp: true, visible: 0), .caughtUp)
        XCTAssertEqual(state(items: 3, visible: 0), .noMatches)
        XCTAssertEqual(state(items: 3, visible: 2), .list)
        for plain in [LibraryScreenState.empty, .caughtUp, .noMatches, .list] { XCTAssertTrue(plain.allowsAddingContent) }
    }
}
