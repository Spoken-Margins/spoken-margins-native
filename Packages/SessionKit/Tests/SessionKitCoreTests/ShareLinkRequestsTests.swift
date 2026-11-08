import XCTest
@testable import SessionKit

/// #3751 audit: a link finished after the listener went back to the selection must not open a share sheet for the
/// old packet. The sender screen cancels the request; its late answer is then refused.
final class ShareLinkRequestsTests: XCTestCase {
    func testTheNewestRequestIsAccepted() {
        var requests = ShareLinkRequests()
        let ticket = requests.begin()
        XCTAssertTrue(requests.accepts(ticket))
    }

    func testALinkFinishedAfterACancelIsRefused() {
        var requests = ShareLinkRequests()
        let ticket = requests.begin()
        requests.cancel()
        XCTAssertFalse(requests.accepts(ticket))
    }

    func testAnOlderRequestIsRefusedOnceANewerOneBegins() {
        var requests = ShareLinkRequests()
        let first = requests.begin()
        requests.cancel()
        let second = requests.begin()
        XCTAssertFalse(requests.accepts(first))
        XCTAssertTrue(requests.accepts(second))
    }

    func testACancelWithNothingOutLeavesTheNextRequestAccepted() {
        var requests = ShareLinkRequests()
        requests.cancel()
        requests.cancel()
        let ticket = requests.begin()
        XCTAssertTrue(requests.accepts(ticket))
    }
}
