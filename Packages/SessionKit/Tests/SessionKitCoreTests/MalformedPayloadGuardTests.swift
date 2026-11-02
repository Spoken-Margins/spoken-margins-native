import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2506 follow-up: the store's SQL "yes/no" and count reads filter on `json_valid(payload)` and then call
/// `json_extract` on the same row. SQLite does not promise that `a AND b` runs `a` first, so a row whose payload is
/// not JSON could make `json_extract` raise "malformed JSON" and fail the whole read. Every such read puts the
/// extraction inside `CASE WHEN json_valid(payload) THEN ... ELSE ... END`, which does promise the order. A row that
/// isn't JSON is left out of the answer, as the whole reads leave out a row they can't decode.
final class MalformedPayloadGuardTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("malformed-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func insertBroken(kind: String, id: String, sessionId: String? = nil, itemId: String? = nil) throws {
        try StoreRawSQL.execute(
            "INSERT INTO records(kind,id,session_id,item_id,payload,updated_at) VALUES(?,?,?,?,'not json','2999-01-01 00:00:00');",
            bindings: [kind, id, sessionId, itemId], at: path)
    }

    func testAnImportedLayerThatIsNotJSONDoesNotFailTheMapQuestion() throws {
        let store = try SQLiteSessionStore(path: path)
        try insertBroken(kind: "imported_commentary_layer", id: "broken-layer", itemId: "item")
        XCTAssertFalse(try store.holdsImportedListeningMap(itemId: "item"))

        let friend = ImportedCommentaryLayer(
            id: "live", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(timeIntervalSince1970: 1_800_000_000),
            listeningMapProposals: [PortableListeningMapProposalArtifact(
                id: "friend-map", createdAt: Date(timeIntervalSince1970: 1_800_000_000), generator: "g", scenes: [])])
        try store.saveImportedCommentaryLayer(friend)
        try insertBroken(kind: "imported_commentary_layer", id: "broken-layer-2", itemId: "item")
        XCTAssertTrue(try store.holdsImportedListeningMap(itemId: "item"))
    }

    func testTheCountsAndPendingSummaryLeaveOutARowThatIsNotJSON() throws {
        let store = try SQLiteSessionStore(path: path)
        try insertBroken(kind: "interjection", id: "s::broken-margin", sessionId: "s")
        try insertBroken(kind: "ai_job", id: "s::broken-job", sessionId: "s")
        try insertBroken(kind: "turn", id: "s::broken-turn", sessionId: "s")
        XCTAssertEqual(try store.activeInterjectionCount(sessionId: "s"), 0)
        XCTAssertEqual(try store.unfinishedAIJobCount(sessionId: "s"), 0)
        XCTAssertNil(try store.latestPendingSummaryTurnId(sessionId: "s"))
        XCTAssertEqual(try store.settleInterruptedAIJobs(), 0)
    }

    /// The class guard: no SQL in the persistence sources tests `json_valid(...)` with a bare `AND`; the extraction
    /// belongs inside the `CASE`. A new query that does is the next instance of this bug.
    func testNoQueryRelyOnAndOrderingAfterJSONValid() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SessionKitPersistence")
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if line.contains("AND json_valid(") || line.contains("json_valid(payload) AND")
                    || line.contains("json_valid(margin.payload) AND") {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "wrap the extraction in CASE WHEN json_valid(payload) THEN ... ELSE ... END")
    }
}
