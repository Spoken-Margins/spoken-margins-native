import XCTest
@testable import SessionKit

/// #3491: a session's description and the start time the listener states, both optional and display-only.
final class LiveSessionDescriptionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(endedAt: Date? = nil) -> LiveSession {
        LiveSession(id: "live-1", kind: .meeting, title: "Sync", startedAt: start, endedAt: endedAt, startPositionMs: 0)
    }

    func testDescriptionIsTrimmedBlankClearsItAndUnchangedWordsRewriteNothing() {
        var live = session()
        LiveSessionEdit.setDescription("  Budget review \n", on: &live)
        XCTAssertEqual(live.sessionDescription, "Budget review")
        let before = live
        LiveSessionEdit.setDescription("Budget review", on: &live)
        XCTAssertEqual(live, before)
        LiveSessionEdit.setDescription("  \n ", on: &live)
        XCTAssertNil(live.sessionDescription)
        var untouched = session()
        LiveSessionEdit.setDescription("", on: &untouched)
        XCTAssertEqual(untouched, session())
    }

    func testStatedStartIsKeptAndNeverTouchesTheStartThatDrivesTheClock() throws {
        var live = session()
        live.margins = [live.margin(id: "a", text: "a", markedAt: start.addingTimeInterval(60))]
        let stated = start.addingTimeInterval(-20 * 60)
        try LiveSessionEdit.setStatedStart(stated, now: start.addingTimeInterval(120), on: &live)
        XCTAssertEqual(live.statedStartedAt, stated)
        XCTAssertEqual(live.startedAt, start)
        XCTAssertEqual(live.margins[0].sessionOffsetMs, 60_000)
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[0], in: live)?.ms, 60_000)
        try LiveSessionEdit.setStatedStart(nil, now: start, on: &live)
        XCTAssertNil(live.statedStartedAt)
    }

    func testStatedStartInTheFutureOrAfterTheEndIsRejectedAndChangesNothing() {
        let now = start.addingTimeInterval(600)
        var running = session()
        XCTAssertThrowsError(try LiveSessionEdit.setStatedStart(now.addingTimeInterval(1), now: now, on: &running)) {
            XCTAssertEqual($0 as? LiveSessionEdit.StatedStartError, .inFuture)
        }
        XCTAssertNil(running.statedStartedAt)
        var ended = session(endedAt: start.addingTimeInterval(300))
        XCTAssertThrowsError(try LiveSessionEdit.setStatedStart(start.addingTimeInterval(301), now: now, on: &ended)) {
            XCTAssertEqual($0 as? LiveSessionEdit.StatedStartError, .afterEnd)
        }
        XCTAssertNil(ended.statedStartedAt)
        XCTAssertNoThrow(try LiveSessionEdit.setStatedStart(start.addingTimeInterval(300), now: now, on: &ended))
    }

    func testNewFieldsRoundTripAndNilWritesNoKey() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = session()
        try LiveSessionStore.save(live, in: directory)
        let plain = try String(contentsOf: LiveSessionStore.url(in: directory), encoding: .utf8)
        XCTAssertFalse(plain.contains("sessionDescription"), plain)
        XCTAssertFalse(plain.contains("statedStartedAt"), plain)

        live.sessionDescription = "About the budget"
        live.statedStartedAt = start.addingTimeInterval(-60)
        try LiveSessionStore.save(live, in: directory)
        XCTAssertEqual(LiveSessionStore.load(from: directory), live)
    }

    func testASessionSavedBeforeTheFieldsExistedStillReads() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desc-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = session()
        live.sessionDescription = "x"
        live.statedStartedAt = start
        try LiveSessionStore.save(live, in: directory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: LiveSessionStore.url(in: directory))) as? [String: Any])
        object["sessionDescription"] = nil
        object["statedStartedAt"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("statedStartedAt"), "fixture edit failed")
        try old.write(to: LiveSessionStore.url(in: directory), options: .atomic)
        let loaded = try XCTUnwrap(LiveSessionStore.load(from: directory))
        XCTAssertNil(loaded.sessionDescription)
        XCTAssertNil(loaded.statedStartedAt)
        XCTAssertEqual(loaded.title, "Sync")
    }

    /// The session shape before #3491, frozen: a session written by this build must decode into it.
    private struct FrozenOldSession: Decodable {
        var id: String
        var title: String
        var startedAt: Date
    }

    func testAnEarlierBuildReadsASessionWithTheNewFields() throws {
        var live = session()
        live.sessionDescription = "About"
        live.statedStartedAt = start.addingTimeInterval(-5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601withFractions
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        let old = try decoder.decode(FrozenOldSession.self, from: encoder.encode(live))
        XCTAssertEqual(old.id, "live-1")
        XCTAssertEqual(old.startedAt, start)
    }
}
