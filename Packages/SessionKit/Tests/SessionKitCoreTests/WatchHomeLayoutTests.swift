import XCTest
@testable import SessionKit

/// #3674: on the owner's Watch the Add a Margin button drew over the skip back, play/pause and skip forward row. The
/// Watch app now draws every button at exactly the height this layout names, so these tests hold the numbers that
/// keep the buttons apart.
final class WatchHomeLayoutTests: XCTestCase {
    func testNoTapTargetTouchesAnother() {
        for sessionRuns in [false, true] {
            let frames = WatchHomeLayout(sessionRuns: sessionRuns).frames
            XCTAssertGreaterThanOrEqual(frames.count, 2)
            for (above, below) in zip(frames, frames.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    below.top - above.bottom, WatchHomeLayout.spacing,
                    "\(above.row) and \(below.row) (session running: \(sessionRuns)) must keep a gap"
                )
            }
        }
    }

    func testEveryTapTargetIsTallEnough() {
        for sessionRuns in [false, true] {
            for frame in WatchHomeLayout(sessionRuns: sessionRuns).frames {
                XCTAssertGreaterThanOrEqual(frame.height, WatchHomeLayout.minimumTapHeight, "\(frame.row)")
            }
        }
    }

    func testTheTransportRowIsAlwaysLastAndBelowAddAMargin() throws {
        for sessionRuns in [false, true] {
            let frames = WatchHomeLayout(sessionRuns: sessionRuns).frames
            XCTAssertEqual(frames.last?.row, .transport)
            let episode = try XCTUnwrap(frames.first { $0.row == .episodeButton })
            let transport = try XCTUnwrap(frames.last)
            XCTAssertLessThan(episode.bottom, transport.top)
        }
    }

    func testTheColumnFitsA41mmWatchAndTheSessionButtonAppearsOnlyWithASession() {
        for sessionRuns in [false, true] {
            let layout = WatchHomeLayout(sessionRuns: sessionRuns)
            XCTAssertLessThanOrEqual(layout.totalHeight, WatchHomeLayout.columnBudget41mm, "session running: \(sessionRuns)")
            XCTAssertEqual(layout.rows.contains(.sessionButton), sessionRuns)
        }
    }

    func testTheThreeTransportButtonsAreEachWideEnoughOnTheSmallestWatch() {
        let width = WatchHomeLayout.transportButtonWidth(contentWidth: WatchHomeLayout.smallestContentWidth)
        XCTAssertGreaterThanOrEqual(width, WatchHomeLayout.minimumTapHeight)
        // Three buttons and their two gaps fill the row, none wider than its share.
        XCTAssertEqual(3 * width + 2 * WatchHomeLayout.transportSpacing + 2 * WatchHomeLayout.sidePadding,
                       WatchHomeLayout.smallestContentWidth, accuracy: 0.001)
    }
}
