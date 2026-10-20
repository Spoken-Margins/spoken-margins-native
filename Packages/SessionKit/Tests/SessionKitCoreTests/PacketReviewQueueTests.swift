import XCTest
@testable import SessionKit

/// #2122: a second packet opened while the first imports must survive the first's completion.
final class PacketReviewQueueTests: XCTestCase {
    private struct Review: Identifiable, Equatable { let id: String }

    func testTheFirstPacketShowsAndASecondWaitsBehindIt() {
        var queue = PacketReviewQueue<Review>()
        XCTAssertEqual(queue.offer(Review(id: "A")), .showing)
        XCTAssertEqual(queue.offer(Review(id: "B")), .waiting(position: 1))
        XCTAssertEqual(queue.offer(Review(id: "C")), .waiting(position: 2))
        XCTAssertEqual(queue.showing, Review(id: "A"))
        XCTAssertEqual(queue.waiting.map(\.id), ["B", "C"])
    }

    func testFinishingTheShowingReviewBringsUpTheNextInOrder() {
        var queue = PacketReviewQueue<Review>()
        queue.offer(Review(id: "A"))
        queue.offer(Review(id: "B"))
        queue.offer(Review(id: "C"))

        XCTAssertTrue(queue.finish("A"))
        XCTAssertEqual(queue.showing, Review(id: "B"))
        XCTAssertTrue(queue.finish("B"))
        XCTAssertEqual(queue.showing, Review(id: "C"))
        XCTAssertTrue(queue.finish("C"))
        XCTAssertNil(queue.showing)
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    func testALateFinishForAReviewNoLongerShowingLeavesTheShowingOneAlone() {
        var queue = PacketReviewQueue<Review>()
        queue.offer(Review(id: "A"))
        queue.offer(Review(id: "B"))
        queue.replaceShowing(with: nil)
        XCTAssertNil(queue.showing)
        queue.offer(Review(id: "C"))

        XCTAssertFalse(queue.finish("A"), "A was taken off screen; its import ending must not clear C")
        XCTAssertEqual(queue.showing, Review(id: "C"))
        XCTAssertEqual(queue.waiting.map(\.id), ["B"])
        XCTAssertFalse(queue.isShowing("A"))
        XCTAssertTrue(queue.isShowing("C"))
    }

    func testFinishingAWaitingReviewTakesItOutOfLineOnly() {
        var queue = PacketReviewQueue<Review>()
        queue.offer(Review(id: "A"))
        queue.offer(Review(id: "B"))
        queue.offer(Review(id: "C"))

        XCTAssertFalse(queue.finish("B"))
        XCTAssertEqual(queue.showing, Review(id: "A"))
        XCTAssertEqual(queue.waiting.map(\.id), ["C"])
        XCTAssertFalse(queue.finish("unknown"))
        XCTAssertEqual(queue.waiting.map(\.id), ["C"])
    }

    func testReplacingTheShowingReviewKeepsTheLine() {
        var queue = PacketReviewQueue<Review>()
        queue.offer(Review(id: "A"))
        queue.offer(Review(id: "B"))

        queue.replaceShowing(with: Review(id: "A2"))

        XCTAssertEqual(queue.showing, Review(id: "A2"))
        XCTAssertFalse(queue.finish("A"), "the rebuilt review is a new one")
        XCTAssertTrue(queue.finish("A2"))
        XCTAssertEqual(queue.showing, Review(id: "B"))
    }
}
