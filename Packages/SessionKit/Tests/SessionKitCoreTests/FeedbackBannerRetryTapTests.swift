import XCTest
@testable import SessionKit

/// #5418: a Margins row's Retry finished, but its result was refused and an older "Retranscription failed." stayed,
/// because a confirmation or warning may not cover an error that offers Retry.
final class FeedbackBannerRetryTapTests: XCTestCase {
    func testTheResultOfARetryTheListenerTappedCoversAnyRetry() {
        for kind in [FeedbackBannerPolicy.Kind.success, .warning] {
            XCTAssertTrue(FeedbackBannerPolicy.mayReplace(
                currentKind: .error, currentOffersRetry: true, with: kind, newAnswersRetryTap: true), "\(kind)")
            XCTAssertTrue(FeedbackBannerPolicy.mayReplace(
                currentKind: .error, currentOffersRetry: true, with: kind,
                currentIsMarginTranscription: true, newAnswersRetryTap: true), "\(kind)")
        }
    }

    func testWithoutATapAnUnansweredRetryStillStays() {
        for kind in [FeedbackBannerPolicy.Kind.success, .warning] {
            XCTAssertFalse(FeedbackBannerPolicy.mayReplace(currentKind: .error, currentOffersRetry: true, with: kind), "\(kind)")
            XCTAssertFalse(FeedbackBannerPolicy.mayReplace(
                currentKind: .error, currentOffersRetry: true, with: kind, currentIsMarginTranscription: true), "\(kind)")
        }
    }
}
