import Foundation
import XCTest
@testable import SessionKit

/// #4927: Record a Margin with nothing running keeps the spoken Margin in a quick session, by the rule a written
/// Margin from Siri follows (`fileWrittenMarginAsQuick`).
final class SpokenMarginQuickFilingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "spoken-quick-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(
        _ worker: LiveSessionFileWorker, id: String = "phone-1", at offset: TimeInterval = 0, audio: String = "/audio/one.m4a"
    ) async -> LiveSession? {
        await worker.fileSpokenMarginAsQuick(
            marginId: id, audioPath: audio, markedAt: t0.addingTimeInterval(offset), durationMs: 4_200, spokenOn: "phone",
            now: t0.addingTimeInterval(offset)
        )
    }

    func testWithNothingRunningASpokenMarginStartsAQuickSessionAtTheMomentItBegan() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "x" })
        let filed = await file(worker, at: 90)
        let session = try XCTUnwrap(filed)
        XCTAssertEqual(session.isQuick, true)
        let margin = try XCTUnwrap(session.margins.first)
        XCTAssertEqual(margin.id, "phone-1")
        XCTAssertEqual(margin.audioPath, "/audio/one.m4a")
        XCTAssertEqual(margin.durationMs, 4_200)
        XCTAssertEqual(margin.spokenOn, "phone")
        XCTAssertTrue(margin.isSpoken)
        XCTAssertFalse(margin.isBlindMark)
        XCTAssertEqual(margin.markedAt, t0.addingTimeInterval(90))
        // It is in the store, where the Library's Live row reads it.
        let stored = await worker.session(id: session.id)
        XCTAssertEqual(stored?.margins.map(\.id), ["phone-1"])
        let summaries = await worker.summaries()
        XCTAssertEqual(summaries.map(\.isQuick), [true])
    }

    func testASecondSpokenMarginSoonAfterReusesTheSameQuickSession() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let first = await file(worker, id: "phone-1", at: 0)
        let second = await file(worker, id: "phone-2", at: 20 * 60, audio: "/audio/two.m4a")
        XCTAssertEqual(first?.id, second?.id)
        let stored = await worker.session(id: try XCTUnwrap(first).id)
        XCTAssertEqual(stored?.margins.map(\.id), ["phone-1", "phone-2"])
        let all = await worker.allSessions()
        XCTAssertEqual(all.count, 1)
    }

    func testAMarginMoreThanHalfAnHourLaterStartsANewQuickSession() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let first = await file(worker, id: "phone-1", at: 0)
        let later = await file(worker, id: "phone-2", at: 2 * 60 * 60, audio: "/audio/two.m4a")
        XCTAssertNotEqual(first?.id, later?.id)
        let all = await worker.allSessions()
        XCTAssertEqual(all.count, 2)
    }

    func testASpokenMarginJoinsTheQuickSessionAWrittenOneStarted() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let written = await worker.fileWrittenMarginAsQuick(text: "written", markedAt: t0, now: t0)
        let spoken = await file(worker, id: "phone-1", at: 20)
        XCTAssertEqual(written?.id, spoken?.id)
        let stored = await worker.session(id: try XCTUnwrap(written).id)
        XCTAssertEqual(stored?.margins.map(\.text), ["written", ""])
        XCTAssertEqual(stored?.margins.map(\.isSpoken), [false, true])
    }

    func testTheSameMarginFiledTwiceIsKeptOnce() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let first = await file(worker)
        let again = await file(worker)
        XCTAssertNotNil(first)
        XCTAssertNil(again)
        let stored = await worker.session(id: try XCTUnwrap(first).id)
        XCTAssertEqual(stored?.margins.count, 1)
    }

    func testAMarginLongAfterANamedSessionEndedStartsAQuickSessionAndLeavesTheNamedOneAlone() async throws {
        let worker = LiveSessionFileWorker(root: root)
        var ended = LiveSession(id: "live", kind: .audiobook, title: "", startedAt: t0)
        ended.endedAt = t0.addingTimeInterval(60)
        try await worker.save(ended, generation: 1)
        let filed = await file(worker, at: 7_200)
        XCTAssertEqual(filed?.isQuick, true)
        XCTAssertNotEqual(filed?.id, "live")
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
    }

    /// The rule is the written Margin's: a session that holds the moment takes it, so a Margin recorded while a live
    /// session runs is never split off into a quick session.
    func testARunningSessionThatHoldsTheMomentTakesItLikeAWrittenMargin() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", kind: .audiobook, title: "", startedAt: t0), generation: 1)
        let spoken = await file(worker, id: "phone-1", at: 30)
        XCTAssertEqual(spoken?.id, "live")
        let written = await worker.fileWrittenMarginAsQuick(text: "written", markedAt: t0.addingTimeInterval(40), now: t0.addingTimeInterval(40))
        XCTAssertEqual(written?.id, "live")
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.isSpoken), [true, false])
    }

    func testAScreenSaveThatHasNotSeenItKeepsTheMargin() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let filed = await file(worker, id: "phone-1", at: 0)
        let first = try XCTUnwrap(filed)
        try await worker.save(first, generation: 1) // the Live row opened the session with its first Margin
        let joined = await file(worker, id: "phone-2", at: 30, audio: "/audio/two.m4a")
        XCTAssertEqual(joined?.id, first.id)
        try await worker.save(first, generation: 2) // the screen's copy, without the second
        let stored = await worker.session(id: first.id)
        XCTAssertEqual(stored?.margins.map(\.id), ["phone-1", "phone-2"])
    }
}
