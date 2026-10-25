import XCTest
@testable import SessionKit

final class MarginGroupOrderingTests: XCTestCase {
    private func entry(_ item: String, _ t: Double) -> MarginGroupOrdering.Entry {
        .init(itemID: item, createdAt: Date(timeIntervalSince1970: t))
    }

    func testGroupsRunNewestMarginFirstAndOnlyFirstIsNewest() {
        // Item A is listed after B but holds the newest Margin overall.
        let groups = MarginGroupOrdering.groups(from: [entry("B", 50), entry("A", 10), entry("A", 90), entry("C", 70)])
        XCTAssertEqual(groups.map(\.itemID), ["A", "C", "B"])
        XCTAssertEqual(groups.map(\.isNewest), [true, false, false])
    }

    func testOneGroupPerItem() {
        let groups = MarginGroupOrdering.groups(from: [entry("A", 1), entry("A", 2), entry("A", 3)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].newestAt, Date(timeIntervalSince1970: 3))
    }

    func testTiesAreStable() {
        let groups = MarginGroupOrdering.groups(from: [entry("Z", 5), entry("A", 5)])
        XCTAssertEqual(groups.map(\.itemID), ["Z", "A"])
    }

    func testEmpty() {
        XCTAssertTrue(MarginGroupOrdering.groups(from: []).isEmpty)
    }
}
