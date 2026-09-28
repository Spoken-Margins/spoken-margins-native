import XCTest
@testable import SessionKit

/// B2 M1: articles never got a manual Follow button, only a suggestion after 25% listened.
final class ManualFollowPolicyTests: XCTestCase {
    func testArticlesWithAnHTTPSLinkOfferFollow() {
        XCTAssertTrue(ManualFollowPolicy.offersFollow(
            mediaType: "text", sourceURL: nil,
            sourceReference: "https://www.astralcodexten.com/p/the-specter-of-neuralese?utm_source=substack"
        ))
        XCTAssertTrue(ManualFollowPolicy.offersFollow(mediaType: "text", sourceURL: "https://garymarcus.substack.com/feed", sourceReference: nil))
    }

    func testArticlesWithoutAWebLinkDoNot() {
        XCTAssertFalse(ManualFollowPolicy.offersFollow(mediaType: "text", sourceURL: nil, sourceReference: nil))
        XCTAssertFalse(ManualFollowPolicy.offersFollow(mediaType: "text", sourceURL: nil, sourceReference: "pasted-text"))
        XCTAssertFalse(ManualFollowPolicy.offersFollow(mediaType: "text", sourceURL: nil, sourceReference: "http://example.com/post"))
    }

    func testPodcastsKeepTheirButtonAndDocumentsStayWithout() {
        XCTAssertTrue(ManualFollowPolicy.offersFollow(mediaType: "podcast", sourceURL: nil, sourceReference: nil))
        XCTAssertTrue(ManualFollowPolicy.offersFollow(mediaType: "transcript_backed_media", sourceURL: nil, sourceReference: nil))
        XCTAssertFalse(ManualFollowPolicy.offersFollow(mediaType: "pdf", sourceURL: nil, sourceReference: "https://arxiv.org/pdf/2401.00001"))
    }
}
