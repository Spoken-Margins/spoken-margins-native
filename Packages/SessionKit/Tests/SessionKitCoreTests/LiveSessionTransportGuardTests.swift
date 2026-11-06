import XCTest
@testable import SessionKit

/// #3492: a Now Playing `play` at 15:06:51Z, inside a live session spoken Margin, started our player and iOS stopped
/// the recorder. The owner chose to ignore that play while the Margin records.
final class LiveSessionTransportGuardTests: XCTestCase {
    func testAStrayNowPlayingPlayDuringARecordingIsIgnored() {
        XCTAssertTrue(LiveSessionTransportGuard.ignores(.play, origin: "now_playing", whileSpokenMarginRecords: true))
        XCTAssertTrue(LiveSessionTransportGuard.ignores(.togglePlayPause, origin: "now_playing", whileSpokenMarginRecords: true))
    }

    func testThePlayIsLetThroughWhenNothingRecords() {
        for command in CompactControlCommand.allCases {
            XCTAssertFalse(LiveSessionTransportGuard.ignores(command, origin: "now_playing", whileSpokenMarginRecords: false), "\(command)")
        }
    }

    func testOnlyCommandsThatStartPlaybackAreHeldBack() {
        let held = CompactControlCommand.allCases.filter {
            LiveSessionTransportGuard.ignores($0, origin: "now_playing", whileSpokenMarginRecords: true)
        }
        XCTAssertEqual(Set(held), [.play, .togglePlayPause])
    }

    func testEveryRemoteOriginIsCovered() {
        for origin in ["now_playing", "now_playing_next_track", "imported_margin_remote"] {
            XCTAssertTrue(LiveSessionTransportGuard.ignores(.play, origin: origin, whileSpokenMarginRecords: true), origin)
        }
    }

    func testATapOnTheAppsOwnPlayButtonStillWorks() {
        for origin in ["app_ui", "compact_url", "", "NOW_PLAYING", "not_now_playing"] {
            XCTAssertFalse(LiveSessionTransportGuard.ignores(.play, origin: origin, whileSpokenMarginRecords: true), origin)
        }
    }
}
