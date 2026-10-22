import XCTest
@testable import SessionKit

/// #2135: a link handed over while another import was resolving cleared the busy flag early and could replace what
/// was playing.
final class SourceLinkImportGateTests: XCTestCase {
    func testTheFlagStaysUpUntilTheLastOverlappingImportEnds() {
        var gate = SourceLinkImportGate()
        gate.begin() // the form's import
        gate.begin() // a link handed over by the share extension
        gate.end()   // the second finishes first
        XCTAssertTrue(gate.isBusy, "the first import is still resolving")
        gate.end()
        XCTAssertFalse(gate.isBusy)
    }

    func testAnUnmatchedEndNeverGoesNegative() {
        var gate = SourceLinkImportGate()
        gate.end()
        gate.begin()
        XCTAssertTrue(gate.isBusy)
        gate.end()
        XCTAssertFalse(gate.isBusy)
    }

    func testAnImportNeverStartsPlaybackOverAnotherSession() {
        XCTAssertTrue(SourceLinkImportGate.mayStartPlayback(requested: true, anotherSessionIsActive: false))
        XCTAssertFalse(SourceLinkImportGate.mayStartPlayback(requested: true, anotherSessionIsActive: true),
                       "a session that began while the link resolved is not replaced")
        XCTAssertFalse(SourceLinkImportGate.mayStartPlayback(requested: false, anotherSessionIsActive: false))
    }
}
