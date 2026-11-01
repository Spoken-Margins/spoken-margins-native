import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Launch settles the AI jobs a killed run left in flight (#2506). It used to walk every Library row and every
/// session; it now asks the store for the sessions that hold such a job. The answer must be the old walk's.
final class InterruptedAIJobRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-ai-job-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openStore(_ name: String, meter: StoreReadMeter? = nil) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: directory.appending(path: "\(name).sqlite").path, readMeter: meter)
    }

    private func session(_ id: String, item: String) -> Session {
        Session(id: id, itemId: item, status: "active", phase: .idle, currentTargetType: .itemTextTTS, currentTargetId: item,
                position: Position(), completionPercent: 0, playbackRate: 1)
    }

    private func job(_ id: String, session: String, status: String, provider: String, turn: String?) -> AIJob {
        AIJob(id: id, kind: "interjection_summary", itemId: nil, sessionId: session, turnId: turn, providerType: provider,
              model: "m", status: status, attempts: 1, lastError: nil, messages: [], playbackMode: nil)
    }

    private func turn(_ id: String, session: String, status: String) -> ConversationTurn {
        ConversationTurn(id: id, sessionId: session, role: "assistant", turnType: "interjection_summary", status: status,
                         summary: nil, text: nil, rawText: nil, sourceInterjectionIds: [])
    }

    /// Items "a" and "b" are in the Library; "gone" is not. Every shape of job and turn the walk could meet.
    private func seed(_ store: SQLiteSessionStore) throws {
        for (id, item) in [("sa", "a"), ("sa2", "a"), ("sb", "b"), ("sgone", "gone"), ("quiet", "b")] {
            try store.saveSession(session(id, item: item))
        }
        try store.saveTurn(turn("t-stream", session: "sa", status: "streaming"))
        try store.saveTurn(turn("t-done", session: "sa", status: "complete"))
        try store.saveTurn(turn("t-remote", session: "sa2", status: "streaming"))
        try store.saveTurn(turn("t-gone", session: "sgone", status: "streaming"))
        try store.saveAIJob(job("j-device-streaming", session: "sa", status: "streaming", provider: "apple_foundation_on_device", turn: "t-stream"))
        try store.saveAIJob(job("j-device-pending-done-turn", session: "sa", status: "pending", provider: "apple_foundation_on_device", turn: "t-done"))
        try store.saveAIJob(job("j-device-no-turn", session: "sb", status: "pending", provider: "apple_foundation_on_device", turn: nil))
        try store.saveAIJob(job("j-remote", session: "sa2", status: "streaming", provider: "openai", turn: "t-remote"))
        try store.saveAIJob(job("j-complete", session: "sa", status: "complete", provider: "apple_foundation_on_device", turn: "t-done"))
        try store.saveAIJob(job("j-retryable", session: "sb", status: "retryable", provider: "apple_foundation_on_device", turn: nil))
        try store.saveAIJob(job("j-failed", session: "quiet", status: "failed", provider: "openai", turn: nil))
        try store.saveAIJob(job("j-gone", session: "sgone", status: "pending", provider: "apple_foundation_on_device", turn: "t-gone"))
    }

    /// The loop this replaced, over the Library's items ("a" and "b").
    private func recoverByWalkingTheLibrary(_ store: SQLiteSessionStore, itemIds: [String]) throws -> Int {
        var recovered = 0
        for itemId in itemIds {
            for session in try store.loadSessions(itemId: itemId) {
                for var job in try store.loadAIJobs(sessionId: session.id) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = job.providerType != "apple_foundation_on_device"
                    job.status = remoteJobDisabled ? "failed" : "retryable"
                    job.lastError = remoteJobDisabled ? "remote_provider_disabled_by_feature_flag" : "app_terminated_during_stream"
                    try store.updateAIJob(job)
                    if let turnId = job.turnId,
                       var turn = try store.loadTurns(sessionId: session.id).first(where: { $0.id == turnId && $0.status == "streaming" }) {
                        turn.status = "failed_partial"
                        try store.saveTurn(turn)
                    }
                    recovered += 1
                }
            }
        }
        return recovered
    }

    private func everything(_ store: SQLiteSessionStore) throws -> (jobs: [AIJob], turns: [ConversationTurn]) {
        let sessions = ["sa", "sa2", "sb", "sgone", "quiet"]
        let jobs = try sessions.flatMap { try store.loadAIJobs(sessionId: $0) }.sorted { $0.id < $1.id }
        let turns = try sessions.flatMap { try store.loadTurns(sessionId: $0) }.sorted { $0.id < $1.id }
        return (jobs, turns)
    }

    func testTheOneQuerySettlesEveryJobTheLibraryWalkDid() throws {
        let walked = try openStore("walked"), asked = try openStore("asked")
        try seed(walked); try seed(asked)

        let walkedCount = try recoverByWalkingTheLibrary(walked, itemIds: ["a", "b"])
        let askedCount = try asked.settleInterruptedAIJobs()

        XCTAssertEqual(walkedCount, 4)
        // The walk never reached the deleted item's session; the query settles its stuck job too, and nothing else differs.
        XCTAssertEqual(askedCount, walkedCount + 1)
        let before = try everything(walked), after = try everything(asked)
        XCTAssertEqual(after.jobs.filter { $0.id != "j-gone" }, before.jobs.filter { $0.id != "j-gone" })
        XCTAssertEqual(after.turns.filter { $0.id != "t-gone" }, before.turns.filter { $0.id != "t-gone" })
        XCTAssertEqual(after.jobs.first { $0.id == "j-gone" }?.status, "retryable")
        XCTAssertEqual(after.turns.first { $0.id == "t-gone" }?.status, "failed_partial")
    }

    func testEachJobEndsInTheStateItsProviderAndTurnCall() throws {
        let store = try openStore("states")
        try seed(store)
        try store.settleInterruptedAIJobs()
        let (jobs, turns) = try everything(store)
        func status(_ id: String) -> String? { jobs.first { $0.id == id }?.status }
        XCTAssertEqual(status("j-device-streaming"), "retryable")
        XCTAssertEqual(jobs.first { $0.id == "j-device-streaming" }?.lastError, "app_terminated_during_stream")
        XCTAssertEqual(status("j-device-pending-done-turn"), "retryable")
        XCTAssertEqual(status("j-device-no-turn"), "retryable")
        XCTAssertEqual(status("j-remote"), "failed")
        XCTAssertEqual(jobs.first { $0.id == "j-remote" }?.lastError, "remote_provider_disabled_by_feature_flag")
        XCTAssertEqual(status("j-complete"), "complete", "a finished job is left alone")
        XCTAssertEqual(status("j-retryable"), "retryable")
        XCTAssertEqual(status("j-failed"), "failed")
        XCTAssertNil(jobs.first { $0.id == "j-complete" }?.lastError)
        XCTAssertEqual(turns.first { $0.id == "t-stream" }?.status, "failed_partial")
        XCTAssertEqual(turns.first { $0.id == "t-remote" }?.status, "failed_partial")
        XCTAssertEqual(turns.first { $0.id == "t-done" }?.status, "complete", "a turn that was not streaming is left alone")
    }

    func testASecondRunHasNothingLeftToSettle() throws {
        let store = try openStore("twice")
        try seed(store)
        XCTAssertEqual(try store.settleInterruptedAIJobs(), 5)
        XCTAssertEqual(try store.settleInterruptedAIJobs(), 0)
    }

    func testALibraryWithNoJobInFlightOpensNoSessionAndNoJob() throws {
        let meter = StoreReadMeter()
        let store = try openStore("quiet", meter: meter)
        for index in 0..<300 {
            try store.saveSession(session("s\(index)", item: "item-\(index)"))
            try store.saveAIJob(job("j\(index)", session: "s\(index)", status: "complete", provider: "apple_foundation_on_device", turn: nil))
        }
        meter.reset()

        XCTAssertEqual(try store.settleInterruptedAIJobs(), 0)

        let totals = meter.totals()
        XCTAssertEqual(totals["sessions_with_interrupted_ai_jobs"]?.rows ?? 0, 0)
        XCTAssertEqual(totals.values.reduce(0) { $0 + $1.calls }, 1, "one read in all: \(totals.keys.sorted())")
        XCTAssertNil(totals["loadAIJobs(sessionId:)"])
        XCTAssertNil(totals["loadSessions(itemId:)"])

        meter.reset()
        _ = try recoverByWalkingTheLibrary(store, itemIds: (0..<300).map { "item-\($0)" })
        XCTAssertEqual(meter.totals().values.reduce(0) { $0 + $1.calls }, 600, "the walk it replaces: a session read and a job read for each of 300 items")
    }

    func testARecordThisBuildCannotReadDoesNotStopTheRest() throws {
        let store = try openStore("malformed")
        try seed(store)
        try store.saveSession(session("sbad", item: "b")); try store.saveSession(session("sshape", item: "b"))
        // Records this build can't read: one is not JSON, one is JSON of the wrong shape. Each sits in a session of its own, and neither may fail the launch or the other sessions.
        let path = directory.appending(path: "malformed.sqlite").path
        try StoreRawSQL.execute([
            "INSERT INTO records(kind,id,session_id,payload,updated_at) VALUES('ai_job','bad','sbad','not json','2999-01-01 00:00:00')",
            "INSERT INTO records(kind,id,session_id,payload,updated_at) VALUES('ai_job','bad-shape','sshape','{\"status\":\"pending\"}','2999-01-01 00:00:00')"
        ], at: path)
        XCTAssertNoThrow(try store.settleInterruptedAIJobs())
        XCTAssertEqual(try store.loadAIJobs(sessionId: "sb").first { $0.id == "j-device-no-turn" }?.status, "retryable")
    }

    // MARK: The source-window retry reads an item's Margins in one query

    private func margin(_ id: String, item: String, session: String) -> Interjection {
        Interjection(id: id, itemId: item, sessionId: session, targetType: .item, targetId: item, createdAt: Date(), roughPercent: 25,
                     anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 80_000),
                     audioPath: nil, audioStatus: "saved", transcriptionStatus: "complete", transcript: "Note \(id)",
                     cleanedTranscript: nil, displayText: nil, status: "active")
    }

    func testAnItemsMarginsInOneReadAreTheSessionBySessionWalk() throws {
        let meter = StoreReadMeter()
        let store = try openStore("margins", meter: meter)
        for (id, item) in [("sa", "a"), ("sa2", "a"), ("sb", "b")] { try store.saveSession(session(id, item: item)) }
        for (id, item, sessionId) in [("m1", "a", "sa"), ("m2", "a", "sa"), ("m3", "a", "sa2"), ("m4", "b", "sb")] {
            try store.saveInterjection(margin(id, item: item, session: sessionId))
        }
        meter.reset()

        let walked = try store.loadSessions(itemId: "a").flatMap { try store.loadInterjections(sessionId: $0.id) }
        let walkCalls = meter.totals().values.reduce(0) { $0 + $1.calls }
        meter.reset()
        let asked = try store.loadInterjections(itemId: "a")

        XCTAssertEqual(Set(asked.map(\.id)), Set(walked.map(\.id)))
        XCTAssertEqual(Set(asked.map(\.id)), ["m1", "m2", "m3"], "another item's Margin is not in it")
        XCTAssertEqual(meter.totals().values.reduce(0) { $0 + $1.calls }, 1)
        XCTAssertEqual(walkCalls, 3, "one read for the sessions, one for each session's Margins")
        // The by-id lookup the retry's caller uses returns the same row the session read found.
        XCTAssertEqual(try store.loadInterjection(id: "m3", sessionId: "sa2"), walked.first { $0.id == "m3" })
        XCTAssertNil(try store.loadInterjection(id: "m3", sessionId: "sa"), "the same id under another session is not it")
        XCTAssertNil(try store.loadInterjection(id: "nope", sessionId: "sa"))
    }
}
