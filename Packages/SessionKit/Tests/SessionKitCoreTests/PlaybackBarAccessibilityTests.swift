import XCTest
@testable import SessionKit

final class PlaybackBarAccessibilityTests: XCTestCase {
    func testMediaPositionsUseMinutesOrHoursAndClampToTheDrawnEndpoints() {
        for (position, length, expected) in [
            (0.0, 3_600.0, "0:00"), (59.9, 3_600, "0:59"), (562, 3_600, "9:22"),
            (3_662, 7_200, "1:01:02"), (-10, 3_600, "0:00"), (4_000, 3_600, "1:00:00"),
        ] {
            XCTAssertEqual(PlaybackBarAccessibility.positionText(position, length: length, unit: .seconds), expected)
        }
    }

    func testTextPositionsDescribeTheSameClampedSourceFractionAsTheBar() {
        for (position, expected) in [(-10.0, "0 percent"), (0, "0 percent"), (399, "40 percent"),
                                     (500, "50 percent"), (1_000, "100 percent"), (2_000, "100 percent")] {
            XCTAssertEqual(PlaybackBarAccessibility.positionText(position, length: 1_000, unit: .characters), expected)
        }
    }

    func testInvalidAndHugeInputsDoNotInventNonfiniteOrOverflowingPositions() {
        for length in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(PlaybackBarAccessibility.positionText(50, length: length, unit: .seconds), "0:00")
            XCTAssertEqual(PlaybackBarAccessibility.positionText(50, length: length, unit: .characters), "0 percent")
        }
        for position in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(PlaybackBarAccessibility.positionText(position, length: 100, unit: .seconds), "0:00")
        }
        let huge = PlaybackBarAccessibility.positionText(.greatestFiniteMagnitude, length: .greatestFiniteMagnitude, unit: .seconds)
        XCTAssertFalse(huge.lowercased().contains("nan"))
        XCTAssertFalse(huge.lowercased().contains("inf"))
        XCTAssertEqual(PlaybackBarAccessibility.positionText(.leastNonzeroMagnitude, length: .leastNonzeroMagnitude, unit: .characters), "100 percent")
    }

    func testLabelsNameOwnershipAndCrowdingWithoutCallingItAReplyThread() {
        let own = PlaybackBarLayout.Mark(id: "mine", position: 562, kind: .own)
        let shared = PlaybackBarLayout.Mark(id: "shared", position: 563, kind: .shared)
        for (members, expected) in [
            ([own], "Your Margin at 9:22"), ([shared], "Shared Margin at 9:23"),
            ([own, shared], "2 Margins at 9:22, 1 shared"),
            (Array(repeating: shared, count: 12), "12 Margins at 9:23, all shared"),
        ] {
            let stack = PlaybackBarLayout.Stack(x: 0, members: members)
            XCTAssertEqual(PlaybackBarAccessibility.label(for: stack, length: 3_600, unit: .seconds), expected)
        }
        let stack = PlaybackBarLayout.Stack(x: 0, members: [own])
        XCTAssertEqual(PlaybackBarAccessibility.label(for: stack, length: 1_124, unit: .characters), "Your Margin at 50 percent")
    }
}
