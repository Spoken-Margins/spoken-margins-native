import Foundation
import XCTest
@testable import SessionKit

/// #4923: "Record a Margin" starts the recording on the running live session, else the player's item, else the start card.
final class RecordMarginRouteTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(title: String = "", kind: ElsewhereKind = .audiobook) -> LiveSession {
        LiveSession(id: "live", kind: kind, title: title, startedAt: t0)
    }

    private func decide(session: LiveSession? = nil, player: Bool = false, recording: Bool = false) -> RecordMarginRoute {
        RecordMarginRoute.decide(.init(runningSession: session, playerHasSession: player, alreadyRecording: recording))
    }

    func testARunningLiveSessionTakesTheRecording() {
        XCTAssertEqual(decide(session: session(title: "Night read")), .liveSession(name: "Night read"))
    }

    func testTheLiveSessionBeatsTheItemInThePlayer() {
        XCTAssertEqual(decide(session: session(), player: true), .liveSession(name: "your audiobook session"))
    }

    func testThePlayerTakesItWithNoLiveSession() {
        XCTAssertEqual(decide(player: true), .playerItem)
    }

    func testNothingRunningOpensTheSessionStartCard() {
        XCTAssertEqual(decide(), .sessionStartCard)
    }

    func testAMarginAlreadyRecordingStartsNoSecondOneWhateverElseRuns() {
        XCTAssertEqual(decide(session: session(), player: true, recording: true), .alreadyRecording)
        XCTAssertEqual(decide(player: true, recording: true), .alreadyRecording)
        XCTAssertEqual(decide(recording: true), .alreadyRecording)
    }

    func testAnUntitledSessionIsNamedByItsKind() {
        XCTAssertEqual(decide(session: session(kind: .meeting)), .liveSession(name: "your meeting session"))
        XCTAssertEqual(decide(session: session(kind: .paper)), .liveSession(name: "your paper book session"))
    }

    func testEachRouteHasItsOwnDiagnosticName() {
        let names = [decide(recording: true), decide(session: session()), decide(player: true), decide()].map(\.diagnosticName)
        XCTAssertEqual(names, ["already_recording", "live_session", "player_item", "session_start_card"])
        XCTAssertEqual(Set(names).count, names.count)
    }
}
