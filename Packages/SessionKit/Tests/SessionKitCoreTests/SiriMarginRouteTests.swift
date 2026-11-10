import Foundation
import XCTest
@testable import SessionKit

/// #3880: Siri's Margin goes to a running live session before the player's item.
final class SiriMarginRouteTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "siri-route-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session(title: String = "", kind: ElsewhereKind = .audiobook) -> LiveSession {
        LiveSession(id: "live", kind: kind, title: title, startedAt: t0)
    }

    func testAChosenItemWinsOverEverything() {
        let facts = SiriMarginRoute.Facts(choseItem: true, runningSession: session(), playerHasSession: true)
        XCTAssertEqual(SiriMarginRoute.decide(facts), .chosenItem)
    }

    func testARunningLiveSessionBeatsTheItemInThePlayer() {
        let facts = SiriMarginRoute.Facts(choseItem: false, runningSession: session(title: "Night read"), playerHasSession: true)
        XCTAssertEqual(SiriMarginRoute.decide(facts), .liveSession(name: "Night read"))
    }

    func testTheLiveSessionRouteHoldsWithNothingInThePlayer() {
        let facts = SiriMarginRoute.Facts(choseItem: false, runningSession: session(), playerHasSession: false)
        XCTAssertEqual(SiriMarginRoute.decide(facts), .liveSession(name: "your audiobook session"))
    }

    func testThePlayerTakesItWithNoLiveSession() {
        let facts = SiriMarginRoute.Facts(choseItem: false, runningSession: nil, playerHasSession: true)
        XCTAssertEqual(SiriMarginRoute.decide(facts), .playerItem)
    }

    func testNothingRunningRefuses() {
        let facts = SiriMarginRoute.Facts(choseItem: false, runningSession: nil, playerHasSession: false)
        XCTAssertEqual(SiriMarginRoute.decide(facts), .nothingRunning)
    }

    func testUntitledSessionsAreNamedByKindAndBlankTitlesCountAsUntitled() {
        XCTAssertEqual(SiriMarginRoute.sessionName(session(kind: .audiobook)), "your audiobook session")
        XCTAssertEqual(SiriMarginRoute.sessionName(session(kind: .meeting)), "your meeting session")
        XCTAssertEqual(SiriMarginRoute.sessionName(session(kind: .paper)), "your paper book session")
        XCTAssertEqual(SiriMarginRoute.sessionName(session(kind: .other)), "your live session")
        XCTAssertEqual(SiriMarginRoute.sessionName(session(title: "  \n", kind: .meeting)), "your meeting session")
        XCTAssertEqual(SiriMarginRoute.sessionName(session(title: " Board call ", kind: .meeting)), "Board call")
    }

    func testTheLines() {
        XCTAssertEqual(SiriMarginRoute.confirmation(named: "your audiobook session"), "Margin added to your audiobook session.")
        XCTAssertEqual(SiriMarginRoute.emptyText, "The Margin was empty, so nothing was saved.")
        XCTAssertEqual(
            SiriMarginRoute.writingInProgress,
            "You're already writing a Margin in Spoken Margins. Save or cancel it, then ask again."
        )
        XCTAssertEqual(
            SiriMarginRoute.nothingRunningMessage,
            "Nothing is running in Spoken Margins. Start a live session or play something, then ask again."
        )
        XCTAssertEqual(SiriMarginRoute.notSaved, "Spoken Margins couldn't save the Margin. Ask again.")
    }

    // MARK: The worker

    func testAWrittenMarginLandsInTheRunningSessionAtThatMoment() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "x" })
        try await worker.save(session(), generation: 1)
        let filed = await worker.addWrittenMargin(text: "  first thought \n", markedAt: t0.addingTimeInterval(90))
        let margin = try XCTUnwrap(filed?.margins.first)
        XCTAssertEqual(margin.text, "first thought")
        XCTAssertEqual(margin.sessionOffsetMs, 90_000)
        XCTAssertFalse(margin.isBlindMark)
        XCTAssertNil(margin.audioPath)
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["first thought"])
    }

    func testAnOpenScreensStaleSaveKeepsTheMargin() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let screen = session()
        try await worker.save(screen, generation: 1)
        await worker.addWrittenMargin(text: "kept", markedAt: t0.addingTimeInterval(5))
        try await worker.save(screen, generation: 2) // the screen's copy, without the Siri Margin
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["kept"])
    }

    func testTwoMarginsInARowAreBothKept() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(session(), generation: 1)
        await worker.addWrittenMargin(text: "one", markedAt: t0.addingTimeInterval(5))
        await worker.addWrittenMargin(text: "two", markedAt: t0.addingTimeInterval(6))
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["one", "two"])
    }

    func testADeletedSessionRefusesIt() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(session(), generation: 1)
        await worker.discard(sessionId: "live", generation: 2)
        let filed = await worker.addWrittenMargin(text: "late", markedAt: t0.addingTimeInterval(5))
        XCTAssertNil(filed)
        let stored = await worker.session(id: "live")
        XCTAssertNil(stored)
    }

    func testAnEndedSessionAndNoSessionRefuseIt() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let none = await worker.addWrittenMargin(text: "nowhere", markedAt: t0)
        XCTAssertNil(none)
        var ended = session()
        ended.endedAt = t0.addingTimeInterval(60)
        try await worker.save(ended, generation: 1)
        let filed = await worker.addWrittenMargin(text: "after", markedAt: t0.addingTimeInterval(120))
        XCTAssertNil(filed)
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
    }

    func testEmptyTextIsNotSaved() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(session(), generation: 1)
        let filed = await worker.addWrittenMargin(text: " \n ", markedAt: t0.addingTimeInterval(5))
        XCTAssertNil(filed)
    }

    func testItNeverGoesIntoAQuickSession() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let quick = LiveSession(id: "q", title: "", startedAt: t0, isQuick: true)
        try await worker.save(quick, generation: 1)
        let filed = await worker.addWrittenMargin(text: "no", markedAt: t0)
        XCTAssertNil(filed)
    }
}
