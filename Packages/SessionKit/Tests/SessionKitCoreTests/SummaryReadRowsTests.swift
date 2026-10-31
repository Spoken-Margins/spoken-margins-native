import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Four main-thread rows that asked for a whole article, a whole fingerprint spine or every turn of a session to answer
/// a yes or no (#2506): the source-transcript check, the cleanup that asks whether an episode has a map, the pending
/// summary lookup, and the "already in the Library" checks. Each must answer exactly as the full read did.
final class SummaryReadRowsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-summary-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openStore(meter: StoreReadMeter? = nil) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path, readMeter: meter)
    }

    // MARK: The summary carries the transcript id

    private func episode(_ id: String, transcriptId: String?) -> Item {
        Item(id: id, title: "Episode \(id)", mediaType: TargetType.transcriptBackedMedia.rawValue,
             text: String(repeating: "A transcript word. ", count: 3_000), externalReference: "https://example.com/\(id)",
             status: "ready", media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/\(id).mp3", durationMs: 90_000),
             transcriptId: transcriptId)
    }

    func testASummaryAnswersTheTranscriptQuestionAsTheWholeItemDoes() throws {
        let store = try openStore()
        try store.saveItem(episode("with", transcriptId: "transcript-1"))
        try store.saveItem(episode("without", transcriptId: nil))

        for pass in ["cut fresh", "read from the kept cut"] {
            for id in ["with", "without"] {
                let summary = try XCTUnwrap(try store.loadItemSummary(id: id), "\(pass) \(id)")
                let item = try store.loadItem(id: id)
                XCTAssertEqual(summary.transcriptId, item.transcriptId, "\(pass) \(id)")
                XCTAssertEqual(summary.media?.durationMs, item.media?.durationMs, "the import also reads the duration: \(pass) \(id)")
                XCTAssertEqual(summary, LibraryItemSummary(item), "\(pass) \(id)")
            }
            XCTAssertEqual(try store.listItemSummaries().first { $0.id == "with" }?.transcriptId, "transcript-1", pass)
        }
    }

    func testASavedTranscriptShowsInTheNextSummary() throws {
        let store = try openStore()
        var item = episode("a", transcriptId: nil)
        try store.saveItem(item)
        XCTAssertNil(try XCTUnwrap(try store.loadItemSummary(id: "a")).transcriptId)

        item.transcriptId = "transcript-new"
        try store.saveItem(item)
        XCTAssertEqual(try store.loadItemSummary(id: "a")?.transcriptId, "transcript-new", "a stale cut must not hide a new transcript")
    }

    // MARK: Is there a fingerprint spine

    private func spine(itemId: String, padding: Int = 0) -> EditionFingerprintSpineArtifact {
        EditionFingerprintSpineArtifact(
            id: "spine-\(itemId)", itemId: itemId, canonicalURL: "https://example.com/" + String(repeating: "x", count: padding),
            landmarks: [])
    }

    func testHasEditionFingerprintSpineAgreesWithTheLoadAndReadsNoPayload() throws {
        let meter = StoreReadMeter()
        let store = try openStore(meter: meter)
        try store.saveEditionFingerprintSpine(spine(itemId: "mapped", padding: 200_000))
        meter.reset()

        XCTAssertTrue(try store.hasEditionFingerprintSpine(itemId: "mapped"))
        XCTAssertFalse(try store.hasEditionFingerprintSpine(itemId: "unmapped"))
        let asked = meter.totals(for: "has_edition_fingerprint_spine")
        XCTAssertEqual(asked.calls, 2)
        XCTAssertLessThan(asked.bytes, 100, "an id is all it reads")

        meter.reset()
        XCTAssertNotNil(try store.loadEditionFingerprintSpine(itemId: "mapped"))
        XCTAssertGreaterThan(meter.totals(for: "loadEditionFingerprintSpine(itemId:)").bytes, 200_000, "the full read it replaces")
    }

    func testHasEditionFingerprintSpineFollowsSaveReplaceAndDelete() throws {
        let store = try openStore()
        XCTAssertFalse(try store.hasEditionFingerprintSpine(itemId: "a"))
        try store.saveEditionFingerprintSpine(spine(itemId: "a"))
        XCTAssertTrue(try store.hasEditionFingerprintSpine(itemId: "a"))
        try store.saveEditionFingerprintSpine(spine(itemId: "a", padding: 5))
        XCTAssertTrue(try store.hasEditionFingerprintSpine(itemId: "a"))
        XCTAssertFalse(try store.hasEditionFingerprintSpine(itemId: "b"), "another item's spine is not this one's")

        try store.saveItem(Item(id: "a", title: "A", mediaType: "text", text: "x", externalReference: nil, status: "ready"))
        try store.deleteItem(id: "a")
        XCTAssertEqual(try store.hasEditionFingerprintSpine(itemId: "a"), try store.loadEditionFingerprintSpine(itemId: "a") != nil)
    }

    // MARK: The newest pending summary turn

    private func turn(_ id: String, session: String = "s", type: String = "interjection_summary", status: String = "pending") -> ConversationTurn {
        ConversationTurn(id: id, sessionId: session, role: "assistant", turnType: type, status: status, summary: nil,
                         text: String(repeating: "Summary text. ", count: 200), rawText: nil, sourceInterjectionIds: [])
    }

    /// What the model did before: every turn of the session, filtered, the last one.
    private func oldAnswer(_ store: SQLiteSessionStore, session: String) throws -> String? {
        try store.loadTurns(sessionId: session)
            .filter { $0.turnType == "interjection_summary" && $0.status != "complete" }
            .last?.id
    }

    func testThePendingSummaryTurnIsTheOneTheOldFilterFound() throws {
        let store = try openStore()
        XCTAssertNil(try store.latestPendingSummaryTurnId(sessionId: "s"), "no turns")

        let steps: [(String, ConversationTurn)] = [
            ("a complete turn is not pending", turn("t1", status: "complete")),
            ("a different turn type is not a summary", turn("t2", type: "interjection_reply", status: "pending")),
            ("another session's pending turn is not this one's", turn("t3", session: "other", status: "pending")),
            ("one pending summary", turn("t4", status: "pending")),
            ("a later failed one counts as not complete", turn("t5", status: "failed")),
            ("a later complete one does not replace it", turn("t6", status: "complete")),
        ]
        for (label, saved) in steps {
            try store.saveTurn(saved)
            XCTAssertEqual(try store.latestPendingSummaryTurnId(sessionId: "s"), try oldAnswer(store, session: "s"), label)
            XCTAssertEqual(try store.latestPendingSummaryTurnId(sessionId: "other"), try oldAnswer(store, session: "other"), label)
        }
        XCTAssertNotNil(try store.latestPendingSummaryTurnId(sessionId: "s"))
        XCTAssertEqual(try store.latestPendingSummaryTurnId(sessionId: "other"), nil, "the other session's turn is not a summary")

        try store.saveTurn(turn("t4", status: "complete"))
        try store.saveTurn(turn("t5", status: "complete"))
        XCTAssertNil(try store.latestPendingSummaryTurnId(sessionId: "s"), "every summary is complete now")
        XCTAssertNil(try oldAnswer(store, session: "s"))
    }

    func testThePendingSummaryLookupReadsAnIdNotTheTurns() throws {
        let meter = StoreReadMeter()
        let store = try openStore(meter: meter)
        for index in 0..<40 { try store.saveTurn(turn("t\(index)", status: index == 39 ? "pending" : "complete")) }
        meter.reset()

        XCTAssertEqual(try store.latestPendingSummaryTurnId(sessionId: "s"), "t39")
        let asked = meter.totals(for: "latest_pending_summary_turn_id")
        XCTAssertEqual(asked.rows, 1)
        XCTAssertLessThan(asked.bytes, 100)

        meter.reset()
        _ = try store.loadTurns(sessionId: "s")
        XCTAssertGreaterThan(meter.totals(for: "loadTurns(sessionId:)").bytes, 40 * 2_000, "the read it replaces decodes every turn")
    }

    // MARK: "Already in the Library" by a summary

    func testASummaryTellsATrashedItemFromAMissingOne() throws {
        let store = try openStore()
        try store.saveItem(episode("a", transcriptId: nil))
        try store.moveItemToTrash(id: "a")
        // The read-later and edition imports ask "is there a row for this id", as `loadItem` answered it.
        XCTAssertNotNil(try? store.loadItemSummary(id: "a"))
        XCTAssertNotNil(try? store.loadItem(id: "a"))
        XCTAssertNil(try store.loadItemSummary(id: "missing"))
        XCTAssertNil(try? store.loadItem(id: "missing"))
    }
}
