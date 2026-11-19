import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import SQLite3
import XCTest
import ZIPFoundation

/// A Margin's Paper note role (#4340) is the listener's own: the last shipped build still decodes the saved Margin,
/// and no packet carries the role.
final class PaperNoteRolePacketTests: XCTestCase {
    private var root: URL!
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperNoteRolePacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func margin(_ id: String, role: PaperNoteRole?) -> Interjection {
        Interjection(
            id: id, itemId: "item-1", sessionId: "session-1", targetType: .item, targetId: "item-1",
            createdAt: createdAt, roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 12, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "A finding.",
            cleanedTranscript: nil, displayText: "A finding.", status: "active", captureKind: .written, paperRole: role
        )
    }

    func testARoleSurvivesSaveAndReloadForEveryRoleAndForNone() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let roles: [PaperNoteRole?] = PaperNoteRole.allCases.map { Optional($0) } + [nil]
        for (index, role) in roles.enumerated() { try store.saveInterjection(margin("m\(index)", role: role)) }
        let loaded = try store.loadInterjections(sessionId: "session-1").sorted { $0.id < $1.id }
        XCTAssertEqual(loaded.map(\.paperRole), roles)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testBuild29DecodesASavedMarginThatCarriesARole() throws {
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.saveInterjection(margin("with-role", role: .keyFinding))
        try store.saveInterjection(margin("without", role: nil))
        let payload = try storedPayload(path, kind: "interjection", idSuffix: "with-role")
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("paperRole"), "the role is really in the stored row")
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "interjection", payload: payload), "with-role")
        let plain = try storedPayload(path, kind: "interjection", idSuffix: "without")
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("paperRole"), "a Margin with no role writes the same row as before")
    }

    func testAPacketFromAMarginWithARoleImportsInBuild29AndCarriesNoRole() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let sent = margin("a-1", role: .evidence)
        try store.saveInterjection(sent)
        let selections = [ReviewedInterjectionSelection(
            packageScopedId: "a-1",
            revision: InterjectionShareRevision(
                id: "revision-a-1", interjectionId: sent.id, itemId: sent.itemId, sessionId: sent.sessionId, createdAt: createdAt,
                approvedTranscript: sent.displayText ?? "", anchorBefore: "", anchorAfter: "", status: .senderApproved
            ),
            anchor: PortableAnchorEvidence(anchorType: .text, exactText: "durable idea"),
            representation: .textOnly
        )]
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-a", createdAt: createdAt,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference, selections: selections,
            senderDisplayLabel: "A", suggestedRevealMode: .companion
        )
        let url = root.appendingPathComponent("package-a.spokenmargins")
        // exportPacket imports it with the last shipped build's reader and compares the Margins it read.
        let manifest = try exportPacket(prepared, to: url)
        try SpokenMarginsPackageExportRecord.recordExport(manifest: manifest, selections: selections, repository: store)

        let archive = try Archive(url: url, accessMode: .read)
        var entries = 0
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            entries += 1
            for word in ["paperRole", "keyFinding"] {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(word), "\(entry.path) carries \(word)")
            }
        }
        XCTAssertGreaterThan(entries, 1)
        // Recording what was shared rewrites the Margin; its role is still there.
        let after = try XCTUnwrap(try store.loadInterjections(sessionId: "session-1").first)
        XCTAssertEqual(after.paperRole, .evidence)
        XCTAssertEqual(after.sharedAs?.count, 1)
    }

    /// The role's raw values are what the sync record and the stored row hold, so renaming a case would orphan them.
    func testTheRoleRawValuesAreFrozen() {
        XCTAssertEqual(PaperNoteRole.allCases.map(\.rawValue), ["purpose", "keyFinding", "evidence"])
    }

    private func storedPayload(_ path: String, kind: String, idSuffix: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM records WHERE kind = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(statement) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(statement, 0)!).hasSuffix(idSuffix) {
                return Data(String(cString: sqlite3_column_text(statement, 1)!).utf8)
            }
        }
        throw SessionKitError.persistenceFailed("no \(kind) record \(idSuffix)")
    }
}
