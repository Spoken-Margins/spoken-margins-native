import Foundation
import SessionKit
import XCTest

final class MicrophonePrimerTests: XCTestCase {
    func testTheLineShowsOnlyWhileTheMicrophoneIsUndetermined() {
        XCTAssertTrue(MicrophonePrimer.isShown(for: .undetermined))
        XCTAssertFalse(MicrophonePrimer.isShown(for: .granted))
        XCTAssertFalse(MicrophonePrimer.isShown(for: .denied))

        var primer = MicrophonePrimer()
        XCTAssertFalse(primer.holds(captureID: UUID(), status: .granted))
        XCTAssertFalse(primer.holds(captureID: UUID(), status: .denied))
        XCTAssertFalse(primer.isShowing)
    }

    func testContinueGoesOnWithThatMarginOnce() {
        var primer = MicrophonePrimer()
        let capture = UUID()
        XCTAssertTrue(primer.holds(captureID: capture, status: .undetermined))
        XCTAssertTrue(primer.isShowing)
        XCTAssertEqual(primer.continueTapped(), capture)
        XCTAssertFalse(primer.isShowing)
        XCTAssertNil(primer.continueTapped(), "A second Continue tap must not request twice")
    }

    func testDismissingCancelsAndTheNextTryShowsItAgain() {
        var primer = MicrophonePrimer()
        XCTAssertTrue(primer.holds(captureID: UUID(), status: .undetermined))
        primer.cancel()
        XCTAssertFalse(primer.isShowing)
        XCTAssertNil(primer.continueTapped(), "Continue after a cancel must not start the cancelled Margin")

        let next = UUID()
        XCTAssertTrue(primer.holds(captureID: next, status: .undetermined))
        XCTAssertEqual(primer.continueTapped(), next)
    }

    func testTheLineIsShortAndPlain() {
        XCTAssertFalse(MicrophonePrimer.message.localizedCaseInsensitiveContains("interjection"))
        let sentences = MicrophonePrimer.message.split(separator: ".").map { $0.split(separator: " ").count }
        XCTAssertTrue(sentences.allSatisfy { $0 <= 12 }, "First-run lines stay at about 12 words a sentence")
    }
}
