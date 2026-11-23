import Foundation
import XCTest
@testable import SessionKit

/// #4233 PR 5 (Design 2.9.1): a Margin filed into a live session keeps what our own player was playing when it was taken,
/// so a later move onto that item can place it. It is written only in the three cases the Design names, it never changes
/// where filing puts the Margin, and it survives a relaunch. These use real files in a temporary folder.
final class LiveSessionPlayingThenTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-playing-then-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// "ep" played from 5 s into it, from t0 to t0 + 200 s, at normal speed.
    private var episodeRun: LiveSessionFiling.PlayerRun {
        .init(itemId: "ep", startedAt: at(0), endedAt: at(200), startPositionMs: 5_000, rate: 1)
    }

    @discardableResult
    private func dropInInbox(
        _ worker: LiveSessionFileWorker, id: String, at offset: TimeInterval, target: WatchItemTarget? = nil
    ) throws -> WatchMarginTransfer {
        let transfer = WatchMarginTransfer(id: id, wallStart: at(offset), durationMs: 2_000, itemTarget: target)
        let received = root.appending(path: "received-\(id).m4a")
        try Data("audio-\(id)".utf8).write(to: received)
        try worker.storeIncoming(fileAt: received, transfer: transfer)
        return transfer
    }

    private func margin(_ id: String, in worker: LiveSessionFileWorker) async -> LiveSessionMargin? {
        await worker.allSessions().flatMap(\.margins).first { $0.id == id }
    }

    // MARK: 1. A named session took it while a run held its time

    func testANamedSessionCoveringARunKeepsTheRunsItemAndPosition() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)
        let transfer = try dropInInbox(worker, id: "talk", at: 100)

        let pass = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(700))

        XCTAssertEqual(pass.answers.first?.sessionId, "meet", "filing is unchanged: the named session takes it")
        XCTAssertEqual(pass.placements, [])
        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 105_000, source: .playerRun))
    }

    func testARunThatEndedWithinTheGraceStillCountsAtItsLastPosition() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)
        let transfer = try dropInInbox(worker, id: "paused", at: 205)

        _ = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(700))

        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 205_000, source: .playerRun))
    }

    func testARunThatEndedBeyondTheGraceIsNotKept() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)
        let transfer = try dropInInbox(worker, id: "later", at: 200 + LiveSessionFiling.itemRunGrace + 1)

        _ = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(700))

        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertNotNil(kept)
        XCTAssertNil(kept?.playingThen)
    }

    func testALockScreenMarkInANamedSessionKeepsTheRun() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)

        _ = await worker.fileMarks([at(50)], playerRuns: [episodeRun], now: at(700))

        let mark = await worker.session(id: "meet")?.margins.first
        XCTAssertEqual(mark?.isBlindMark, true)
        XCTAssertEqual(mark?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 55_000, source: .playerRun))
    }

    func testAMarkJustAfterARunEndedGoesToAQuickSessionAndKeepsTheRunsLastPosition() async throws {
        // Filing's step 5 takes only a run that holds the time exactly, so this Mark goes to a quick session; the hint
        // uses the 10-second grace the Design names for case 1, at the run's last position.
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let pass = await worker.fileMarks([at(205)], playerRuns: [episodeRun], now: at(300))

        XCTAssertEqual(pass.placements, [])
        let mark = await worker.allSessions().first?.margins.first
        XCTAssertEqual(mark?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 205_000, source: .playerRun))
    }

    // MARK: 2. The playing item refused it

    func testARefusedPlacementKeepsItsItemAndPositionInTheQuickSession() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let transfer = try dropInInbox(worker, id: "pod", at: 100)
        let pass = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(200))
        let placement = try XCTUnwrap(pass.placements.first)
        XCTAssertEqual(placement.itemId, "ep")

        let session = await worker.fileAsQuickSession(placement, now: at(200))

        XCTAssertEqual(session?.isQuick, true)
        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 105_000, source: .playerRun))
    }

    func testARefusedMarginAimedAtAnItemKeepsTheWatchsPositionAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let transfer = try dropInInbox(worker, id: "aimed", at: 100, target: WatchItemTarget(itemId: "ep", positionMs: 7_000))
        let pass = await worker.fileWatchInbox(playerRuns: [], now: at(105))
        let placement = try XCTUnwrap(pass.placements.first)

        _ = await worker.fileAsQuickSession(placement, now: at(105))

        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 7_000, source: .watchTarget))
    }

    func testARefusedLockScreenMarkKeepsItsItemAndPosition() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let pass = await worker.fileMarks([at(50)], playerRuns: [episodeRun], now: at(200))
        let placement = try XCTUnwrap(pass.placements.first)

        let session = await worker.fileAsQuickSession(placement, now: at(200))

        XCTAssertEqual(
            session?.margins.first?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 55_000, source: .playerRun)
        )
    }

    // MARK: 3. A Watch target with no position

    func testAWatchTargetWithNoPositionKeepsTheItemWithNoPosition() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let transfer = try dropInInbox(worker, id: "aimed", at: 100, target: WatchItemTarget(itemId: "ep", positionMs: nil))

        let pass = await worker.fileWatchInbox(playerRuns: [], now: at(105))

        XCTAssertEqual(pass.placements, [], "filing can't use a target with no position")
        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: nil, source: .watchTarget))
    }

    func testAWatchTargetIsKeptOverARunOfAnotherItem() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let transfer = try dropInInbox(worker, id: "aimed", at: 100, target: WatchItemTarget(itemId: "book", positionMs: nil))

        _ = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(105))

        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "book", positionMs: nil, source: .watchTarget))
    }

    // MARK: 4. Nothing playing, nothing aimed at: no hint

    func testNoRunAndNoTargetKeepsNothing() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let transfer = try dropInInbox(worker, id: "plain", at: 100)

        _ = await worker.fileWatchInbox(playerRuns: [], now: at(105))

        let kept = await margin(transfer.marginId, in: worker)
        XCTAssertNotNil(kept)
        XCTAssertNil(kept?.playingThen)
    }

    func testSirisWrittenMarginsKeepNothing() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        let quick = await worker.fileWrittenMarginAsQuick(text: "remember this", markedAt: at(100), now: at(100))
        XCTAssertNil(quick?.margins.first?.playingThen)

        try await worker.save(LiveSession(id: "live", startedAt: at(0)), generation: 1)
        let running = await worker.addWrittenMargin(text: "and this", markedAt: at(150))
        XCTAssertEqual(running?.margins.count, 1)
        XCTAssertNil(running?.margins.first?.playingThen)
    }

    // MARK: 5. Filing decisions are unchanged

    /// Each row: the Margin, the sessions and runs, and what `decide` gave before this PR. `decide` is untouched; this
    /// table pins it so a later change to the hint can't move a Margin.
    func testDecideGivesTheSameResultsAsBefore() {
        let meeting = LiveSessionFiling.Candidate(id: "meet", startedAt: at(0), endedAt: at(600), marginIds: ["old"])
        let quick = LiveSessionFiling.Candidate(id: "quick", startedAt: at(1_000), endedAt: at(1_000), isQuick: true)
        let run = episodeRun
        let rows: [(String, LiveSessionFiling.Incoming, [LiveSessionFiling.Candidate], [LiveSessionFiling.PlayerRun], LiveSessionFiling.Decision)] = [
            ("in the span, a run playing", .init(marginId: "a", markedAt: at(100)), [meeting], [run], .session(id: "meet", placement: .withinSpan)),
            ("in the span, nothing playing", .init(marginId: "a", markedAt: at(100)), [meeting], [], .session(id: "meet", placement: .withinSpan)),
            ("already filed", .init(marginId: "old", markedAt: at(100)), [meeting], [run], .alreadyFiled(sessionId: "meet")),
            ("player only", .init(marginId: "a", markedAt: at(100)), [], [run], .playerItem(itemId: "ep", positionMs: 105_000)),
            ("player not allowed", .init(marginId: "a", markedAt: at(100), allowsPlayerItem: false), [], [run], .newQuick),
            ("within the grace only", .init(marginId: "a", markedAt: at(205)), [], [run], .newQuick),
            ("aimed, run of it", .init(marginId: "a", markedAt: at(100), itemTarget: .init(itemId: "ep")), [meeting], [run],
             .playerItem(itemId: "ep", positionMs: 105_000)),
            ("aimed, no position", .init(marginId: "a", markedAt: at(100), itemTarget: .init(itemId: "book")), [], [run], .newQuick),
            ("aimed with position", .init(marginId: "a", markedAt: at(100), itemTarget: .init(itemId: "book", positionMs: 9_000)), [], [run],
             .playerItem(itemId: "book", positionMs: 9_000)),
            ("near a quick session", .init(marginId: "a", markedAt: at(1_100)), [meeting, quick], [], .joinQuick(id: "quick")),
            ("names an unknown session", .init(marginId: "a", markedAt: at(5_000), sessionId: "w"), [meeting], [run], .newNamedSession(id: "w")),
            ("after the end, named", .init(marginId: "a", markedAt: at(700), sessionId: "meet"), [meeting], [run],
             .session(id: "meet", placement: .afterEnd)),
        ]
        let deletions = LiveSessionFiling.Deletions(sessions: [], marginIds: ["gone"])
        for (name, incoming, sessions, runs, expected) in rows {
            let decision = LiveSessionFiling.decide(incoming, sessions: sessions, deletions: deletions, playerRuns: runs, now: at(9_000))
            XCTAssertEqual(decision, expected, name)
        }
        let refused = LiveSessionFiling.Incoming(marginId: "gone", markedAt: at(100))
        let decision = LiveSessionFiling.decide(refused, sessions: [meeting], deletions: deletions, playerRuns: [run], now: at(9_000))
        XCTAssertEqual(decision, .rejected(.marginDeleted))
        XCTAssertNil(LiveSessionFiling.playingThen(for: refused, decision: decision, playerRuns: [run]), "a refused Margin keeps nothing")
    }

    // MARK: 6. It survives a relaunch

    func testARebuiltWorkerKeepsTheHint() async throws {
        let first = LiveSessionFileWorker(root: root)
        try await first.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)
        let transfer = try dropInInbox(first, id: "talk", at: 100)
        _ = await first.fileWatchInbox(playerRuns: [episodeRun], now: at(700))

        // The app ends; the player's runs are gone with it.
        let relaunched = LiveSessionFileWorker(root: root)
        let kept = await margin(transfer.marginId, in: relaunched)

        XCTAssertEqual(kept?.playingThen, LiveSessionPlayingThen(itemId: "ep", positionMs: 105_000, source: .playerRun))
    }

    func testAScreenSaveOfTheSessionKeepsTheHint() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: at(0), endedAt: at(600)), generation: 1)
        let transfer = try dropInInbox(worker, id: "talk", at: 100)
        _ = await worker.fileWatchInbox(playerRuns: [episodeRun], now: at(700))

        // The screen took the filed session and the listener renamed it.
        let filed = await worker.session(id: "meet")
        var shown = try XCTUnwrap(filed)
        shown.title = "Standup"
        _ = try await worker.save(shown, generation: 2)

        let kept = await margin(transfer.marginId, in: LiveSessionFileWorker(root: root))
        XCTAssertEqual(kept?.playingThen?.itemId, "ep")
    }

    // MARK: 7. The JSON stays readable both ways

    func testASessionFromBeforeThisPRDecodes() throws {
        let json = #"{"id":"live","kind":"meeting","title":"","startedAt":"2027-01-15T08:00:00.000Z","margins":[{"id":"m","text":"hi","markedAt":"2027-01-15T08:00:01.000Z","sessionOffsetMs":1000,"isBlindMark":false}]}"#
        try FileManager.default.createDirectory(at: LiveSessionStore.url(in: root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: LiveSessionStore.url(in: root))
        let read = try XCTUnwrap(LiveSessionStore.load(from: root))
        XCTAssertEqual(read.margins.first?.savedText, "hi")
        XCTAssertNil(read.margins.first?.playingThen)
    }

    func testTheHintRoundTripsAndALaterBuildsSourceStillReads() throws {
        var session = LiveSession(id: "live", startedAt: t0)
        var margin = LiveSessionMargin(id: "m", text: "hi", markedAt: at(1))
        margin.playingThen = LiveSessionPlayingThen(itemId: "ep", positionMs: nil, source: .watchTarget)
        session.add(margin)
        try LiveSessionStore.save(session, in: root)
        XCTAssertEqual(LiveSessionStore.load(from: root)?.margins.first?.playingThen, margin.playingThen)

        let later = #"{"itemId":"ep","positionMs":1200,"source":"carPlay"}"#
        let read = try JSONDecoder().decode(LiveSessionPlayingThen.self, from: Data(later.utf8))
        XCTAssertEqual(read, LiveSessionPlayingThen(itemId: "ep", positionMs: 1_200, source: .unknown))
    }
}
