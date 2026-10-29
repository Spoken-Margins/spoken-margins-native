import Foundation
import XCTest
@testable import SessionKit

/// #2709 point 7: the Watch's End offers "when did it end?", and "Ended 14:05 · Resume" shows when it stopped.
final class LiveSessionStoppedOnWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-stopped-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func envelope(_ message: WatchMessage, sentAt minutes: Double) -> WatchEnvelope {
        WatchEnvelope(seq: 1, sentAt: at(minutes), clock: nil, message: message)
    }

    private func info(_ kind: WatchSessionKind = .audiobook) -> WatchSessionInfo {
        WatchSessionInfo(id: "live-w", kind: kind, title: kind.label, owner: .watch, startedAt: t0)
    }

    // MARK: The choices

    func testTheWatchOffersTheSameChoicesAsThePhoneAndOnlyThoseInsideTheSession() {
        let tapped = at(60)
        let phone = LiveSessionEnd.quickChoices(startedAt: t0, tappedAt: tapped).map(\.label)
        XCTAssertEqual(WatchEndChoice.choices(startedAt: t0, tappedAt: tapped).map(\.label), phone)
        XCTAssertEqual(phone, ["Now", "5 minutes ago", "15 minutes ago", "30 minutes ago", "1 hour ago"])
        XCTAssertEqual(WatchEndChoice.choices(startedAt: at(40), tappedAt: tapped).map(\.label), ["Now", "5 minutes ago", "15 minutes ago"])
        XCTAssertEqual(WatchEndChoice.minutesAgo(15).date(tappedAt: tapped), at(45))
    }

    // MARK: On the Watch

    func testEndingEarlierKeepsTheStoppedTimeForTheLineAndTheTapForTheWindow() throws {
        var model = WatchSessionModel()
        _ = model.start(kind: .audiobook, id: "live-w", now: t0)
        let ended = try XCTUnwrap(model.end(now: at(60), stoppedAt: at(45)))
        XCTAssertEqual(ended.endedAt, at(60))
        XCTAssertEqual(ended.stoppedAt, at(45))
        let resumable = try XCTUnwrap(model.home(now: at(61), phoneReachable: true).resumable)
        XCTAssertEqual(resumable.shownEnd, at(45), "“Ended 14:05” is when it stopped")
        XCTAssertEqual(resumable.endedAt, at(60))
        // Ten minutes run from the tap: 55 minutes after the stopped time is still inside the window.
        XCTAssertNotNil(model.home(now: at(60 + 9), phoneReachable: true).resumable)
        XCTAssertNil(model.home(now: at(60 + 11), phoneReachable: true).resumable)
    }

    func testNowAndNoStoppedTimeChangeNothing() throws {
        var model = WatchSessionModel()
        _ = model.start(kind: .audiobook, id: "live-w", now: t0)
        let ended = try XCTUnwrap(model.end(now: at(60), stoppedAt: at(60).addingTimeInterval(-0.5)))
        XCTAssertNil(ended.stoppedAt)
        XCTAssertEqual(model.home(now: at(61), phoneReachable: true).resumable?.shownEnd, at(60))
    }

    func testAStoppedTimeBeforeTheStartIsBroughtBackToTheStart() throws {
        var model = WatchSessionModel()
        _ = model.start(kind: .audiobook, id: "live-w", now: at(50))
        let ended = try XCTUnwrap(model.end(now: at(60), stoppedAt: at(10)))
        XCTAssertEqual(ended.stoppedAt, at(50))
    }

    func testResumingDropsTheStoppedTime() throws {
        var model = WatchSessionModel()
        _ = model.start(kind: .audiobook, id: "live-w", now: t0)
        _ = try XCTUnwrap(model.end(now: at(60), stoppedAt: at(45)))
        XCTAssertEqual(model.resume(now: at(62)), "live-w")
        XCTAssertNil(model.home(now: at(63), phoneReachable: true).resumable)
    }

    // MARK: On the phone

    func testThePhoneEndsAtTheStoppedTimeKeepsTheTapAndNotesLateMargins() async throws {
        let worker = LiveSessionFileWorker(root: root)
        _ = await worker.applyWatch(envelope(.sessionStart(info()), sentAt: 0), now: at(0))
        let stored = await worker.session(id: "live-w")
        var session = try XCTUnwrap(stored)
        session.margins = [
            session.margin(id: "in", text: "during", markedAt: at(30)),
            session.margin(id: "late", text: "after", markedAt: at(50)),
        ]
        let sessions = ["live-w": session]
        let ended = try XCTUnwrap(LiveSessionWatchSessions.end(id: "live-w", endedAt: at(60), stoppedAt: at(45), clock: nil, sessions: sessions))
        XCTAssertEqual(ended.endedAt, at(45))
        XCTAssertEqual(ended.endTappedAt, at(60))
        XCTAssertEqual(ended.endHeardAt, at(60))
        XCTAssertNil(ended.margins.first { $0.id == "in" }?.filingNote)
        XCTAssertEqual(ended.margins.first { $0.id == "late" }?.filingNote, LiveSessionFiling.afterEndNote)
        // The board tells the Watch both: the tap for the window, the stopped time for the line.
        let board = LiveSessionWatchSessions.board(sessions: [ended], now: at(61))
        XCTAssertEqual(board.recentlyEnded?.endedAt, at(60))
        XCTAssertEqual(board.recentlyEnded?.stoppedAt, at(45))
    }

    func testResumingBringsTheGapsMarginsBackInsideTheSession() throws {
        var live = LiveSession(id: "live-w", kind: .audiobook, startedAt: t0)
        live.margins = [live.margin(id: "gap", text: "x", markedAt: at(50))]
        let ended = try XCTUnwrap(LiveSessionWatchSessions.end(id: "live-w", endedAt: at(60), stoppedAt: at(45), clock: nil, sessions: ["live-w": live]))
        XCTAssertEqual(ended.margins[0].filingNote, LiveSessionFiling.afterEndNote)
        let resumed = try XCTUnwrap(LiveSessionWatchSessions.resume(id: "live-w", at: at(62), sessions: ["live-w": ended]))
        XCTAssertNil(resumed.endedAt)
        XCTAssertNil(resumed.margins[0].filingNote)
    }

    func testAMessageWithNoStoppedTimeEndsAtOnceAsBefore() async throws {
        let worker = LiveSessionFileWorker(root: root)
        _ = await worker.applyWatch(envelope(.sessionStart(info()), sentAt: 0), now: at(0))
        _ = await worker.applyWatch(envelope(.sessionEnd(id: "live-w", endedAt: at(60)), sentAt: 60), now: at(60))
        let stored = await worker.session(id: "live-w")
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(session.endedAt, at(60))
        XCTAssertNil(session.endTappedAt)
    }

    func testAStoppedTimeAfterTheTapOrBeforeTheStartIsBroughtInside() throws {
        let live = LiveSession(id: "live-w", kind: .audiobook, startedAt: at(10))
        let early = try XCTUnwrap(LiveSessionWatchSessions.end(id: "live-w", endedAt: at(60), stoppedAt: at(1), clock: nil, sessions: ["live-w": live]))
        XCTAssertEqual(early.endedAt, at(10))
        let future = try XCTUnwrap(LiveSessionWatchSessions.end(id: "live-w", endedAt: at(60), stoppedAt: at(90), clock: nil, sessions: ["live-w": live]))
        XCTAssertEqual(future.endedAt, at(60))
        XCTAssertNil(future.endTappedAt)
    }

    // MARK: The wire

    func testTheMessageRoundTripsAndOneFromAnEarlierBuildStillReads() throws {
        let message = WatchMessage.sessionEnd(id: "s", endedAt: at(60), stoppedAt: at(45))
        let wrapped = WatchEnvelope(seq: 1, sentAt: t0, clock: nil, message: message)
        XCTAssertTrue(PropertyListSerialization.propertyList(wrapped.dictionary, isValidFor: .binary))
        XCTAssertEqual(WatchEnvelope(dictionary: wrapped.dictionary)?.message, message)

        let old = WatchMessage.sessionEnd(id: "s", endedAt: at(60))
        let oldJSON = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(oldJSON.contains("stoppedAt"), oldJSON)
        XCTAssertEqual(try JSONDecoder().decode(WatchMessage.self, from: Data(oldJSON.utf8)), old)
    }
}
