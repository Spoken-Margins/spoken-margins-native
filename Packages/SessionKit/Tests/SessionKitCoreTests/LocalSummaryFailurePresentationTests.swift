import XCTest
@testable import SessionKit

final class LocalSummaryFailurePresentationTests: XCTestCase {
    private let descriptions = [
        "",
        "  ",
        "GenerationError.exceededContextWindowSize(tokens: 4096)",
        "The model could not finish.\nNo cleaned-transcript fallback was saved.\nTry another prompt.",
        "Résumé — Cafe\u{0301} ☕",
        String(repeating: "A technical model error. ", count: 500)
    ]

    func testFeedbackStaysShortForEveryModelErrorDescription() {
        for description in descriptions {
            let presentation = LocalSummaryFailurePresentation(errorDescription: description)
            XCTAssertEqual(presentation.feedbackMessage, "Summary couldn’t finish.")
        }
    }

    func testItemDetailRetainsTheWholeDescriptionAndExistingRetryGuidance() {
        for description in descriptions {
            let presentation = LocalSummaryFailurePresentation(errorDescription: description)
            XCTAssertEqual(presentation.detailMessage,
                           "On-device summary failed: \(description) Tap Retry Summary to try the model again.")
        }
    }
}
