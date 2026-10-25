import Foundation
import XCTest
@testable import SessionKit

/// #2487 slice 1a: the session store of many sessions takes in today's `LiveSession/current.json` without loss, and
/// keeps writing `current.json` in a form the build before it reads. Real files in a temporary Application Support.
final class LiveSessionCollectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var currentURL: URL { LiveSessionStore.url(in: root) }

    /// `current.json` exactly as the build before this one writes it (sorted keys, ISO 8601 with milliseconds): a
    /// running meeting with a typed Margin, a Lock Screen Mark and a Watch Margin with its transcript.
    private let todaysCurrentJSON = """
    {"id":"live-7c1f","kind":"meeting","margins":[\
    {"id":"a1","isBlindMark":false,"markedAt":"2027-01-15T08:01:40.250Z","sessionOffsetMs":100250,"text":"Budget is late","whereNote":"slide 4"},\
    {"id":"mark-1800000200000","isBlindMark":true,"markedAt":"2027-01-15T08:03:20.000Z","sessionOffsetMs":200000,"text":""},\
    {"audioPath":"SpokenMargins/interjections/watch-w1.m4a","durationMs":2400,"id":"watch-w1","isBlindMark":false,"markedAt":"2027-01-15T08:05:00.000Z","sessionOffsetMs":300000,"spokenOn":"watch","text":"ask Johnny"}],\
    "startPositionMs":0,"startedAt":"2027-01-15T08:00:00.000Z","title":"Budget meeting"}
    """

    private func writeTodaysCurrent() throws {
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(todaysCurrentJSON.utf8).write(to: currentURL)
    }

    func testTodaysCurrentFileIsTakenInWithoutLoss() async throws {
        try writeTodaysCurrent()
        let legacy = try XCTUnwrap(LiveSessionStore.load(from: root))
        let worker = LiveSessionFileWorker(root: root)

        let running = await worker.runningSession()
        XCTAssertEqual(running, legacy)
        XCTAssertEqual(running?.margins.map(\.id), ["a1", "mark-1800000200000", "watch-w1"])
        XCTAssertEqual(running?.margins.last?.spokenTranscript, "ask Johnny")
        XCTAssertEqual(running?.margins.first?.whereNote, "slide 4")
        let stored = LiveSessionCollection(root: root).loadAll()
        XCTAssertEqual(stored, [legacy])
        // `current.json` is left for the build before this one, still a running session it can open.
        XCTAssertEqual(try Data(contentsOf: currentURL), Data(todaysCurrentJSON.utf8))
    }

    /// A session's start, saved and loaded again and again, stays where the first save put it: the nearest millisecond.
    /// The format style truncates, and a millisecond read back sits a hair under itself, so each later save dropped one
    /// (a start of …56.668066 came back from the store as …56.667 on the lane, #2543).
    func testAStartSavedAndLoadedRepeatedlyKeepsItsMillisecond() throws {
        for offset in [0.668066, 0.0004999, 0.0005, 0.999_6, 0.123, 0.5] {
            let started = Date(timeIntervalSince1970: 1_792_873_556 + offset)
            let nearestMs = (started.timeIntervalSince1970 * 1_000).rounded() / 1_000
            var session = LiveSession(id: "live-ms", title: "Budget meeting", startedAt: started)
            for _ in 0 ..< 5 {
                try LiveSessionStore.save(session, in: root)
                session = try XCTUnwrap(LiveSessionStore.load(from: root))
                XCTAssertEqual(session.startedAt.timeIntervalSince1970, nearestMs, accuracy: 0.000_01, "offset \(offset)")
            }
        }
    }

    func testTheBuildBeforeThisOneStillReadsCurrentJSONAfterThisBuildWritesIt() async throws {
        try writeTodaysCurrent()
        let worker = LiveSessionFileWorker(root: root)
        let loaded = await worker.runningSession()
        var session = try XCTUnwrap(loaded)
        var watch = session.margin(id: "watch-w2", text: "", markedAt: t0.addingTimeInterval(400))
        watch.filingNote = LiveSessionFiling.afterEndNote
        session.margins.append(watch)
        session.isQuick = false
        try await worker.save(session, generation: 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        let previous = try decoder.decode(PreviousBuildLiveSession.self, from: Data(contentsOf: currentURL))
        XCTAssertEqual(previous.id, "live-7c1f")
        XCTAssertNil(previous.endedAt)
        XCTAssertEqual(previous.margins.map(\.id), ["a1", "mark-1800000200000", "watch-w1", "watch-w2"])
    }

    func testMarginsAnEarlierBuildAddedAfterADowngradeAreMergedIn() throws {
        try writeTodaysCurrent()
        let collection = LiveSessionCollection(root: root)
        XCTAssertTrue(try collection.migrateLegacyCurrent())
        XCTAssertFalse(try collection.migrateLegacyCurrent(), "a second pass changes nothing")

        // The earlier build adds a Margin and ends the session in current.json.
        var legacy = try XCTUnwrap(LiveSessionStore.load(from: root))
        legacy.margins.append(legacy.margin(id: "late", text: "written on the old build", markedAt: legacy.startedAt.addingTimeInterval(500)))
        legacy.endedAt = legacy.startedAt.addingTimeInterval(600)
        try LiveSessionStore.save(legacy, in: root)

        XCTAssertTrue(try collection.migrateLegacyCurrent())
        let stored = try XCTUnwrap(collection.loadAll().first)
        XCTAssertEqual(stored.margins.map(\.id), ["a1", "mark-1800000200000", "watch-w1", "late"])
        XCTAssertEqual(stored.endedAt, legacy.endedAt)
    }

    func testADeletedSessionInCurrentJSONStaysDeleted() async throws {
        try writeTodaysCurrent()
        let worker = LiveSessionFileWorker(root: root)
        _ = await worker.runningSession()
        await worker.discard(sessionId: "live-7c1f", generation: 1)
        XCTAssertNil(LiveSessionStore.load(from: root), "the earlier build no longer sees it either")

        try writeTodaysCurrent() // a stale copy comes back
        let again = LiveSessionFileWorker(root: root)
        let running = await again.runningSession()
        XCTAssertNil(running)
        let deletions = await again.currentDeletions()
        XCTAssertTrue(deletions.marginIds.isSuperset(of: ["a1", "watch-w1"]))
    }

    func testCurrentJSONHoldsTheRunningNamedSessionNeverAQuickOne() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q" })
        _ = await worker.fileMarks([t0], now: t0)
        XCTAssertNil(LiveSessionStore.load(from: root))

        try await worker.save(LiveSession(id: "meet", startedAt: t0.addingTimeInterval(100)), generation: 1)
        XCTAssertEqual(LiveSessionStore.load(from: root)?.id, "meet")

        await worker.markSaved(sessionId: "meet", itemId: "item-1", now: t0.addingTimeInterval(200))
        XCTAssertNil(LiveSessionStore.load(from: root), "a saved session leaves current.json, as the earlier build's save did")
        let saved = await worker.session(id: "meet")
        XCTAssertEqual(saved?.savedItemId, "item-1")
        let rows = await worker.summaries(now: t0.addingTimeInterval(200))
        XCTAssertEqual(rows.map(\.id), ["quick-q"])
    }

    func testAnUnreadableSessionFileIsSkippedAndKept() throws {
        let collection = LiveSessionCollection(root: root)
        try collection.save(LiveSession(id: "good", startedAt: t0))
        let bad = collection.directory.appending(path: "bad.json")
        try Data("{not json".utf8).write(to: bad)
        XCTAssertEqual(collection.loadAll().map(\.id), ["good"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }

    func testOddSessionIdsGetDistinctFileNames() {
        let names = ["live-1", "live/1", "live:1", "live 1", "é"].map(LiveSessionCollection.fileName(for:))
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names[0], "live-1.json")
        XCTAssertFalse(names.contains { $0.contains("/") })
    }
}

/// `LiveSession` as the build before slice 1a decodes it (main at 285aaa05), to prove it still reads what this build writes.
private struct PreviousBuildLiveSession: Decodable {
    struct Margin: Decodable {
        var id: String
        var text: String
        var markedAt: Date
        var sessionOffsetMs: Int
        var whereNote: String?
        var isBlindMark: Bool
        var listenerPositionMs: Int?
        var audioPath: String?
        var durationMs: Int?
        var spokenOn: String?
    }

    var id: String
    var kind: ElsewhereKind
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var startPositionMs: Int?
    var endPositionMs: Int?
    var startWhere: String?
    var endWhere: String?
    var margins: [Margin]
}
