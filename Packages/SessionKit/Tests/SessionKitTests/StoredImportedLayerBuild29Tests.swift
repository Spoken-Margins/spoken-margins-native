import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import SQLite3
import XCTest

/// Build 29 can still open the imported-Margin layer this build saves (PKT-10 of the #1039 audit). AGENTS.md: the
/// previous build must open the database, or a TestFlight downgrade loses every imported shared Margin's source
/// status, reveal mode and map evidence. MarginReplyPacketTests and EpisodeGUIDSharingTests decode the item,
/// feed entry, Margin and imported-Margin rows with Build 29's types; nothing decoded `imported_commentary_layer`,
/// the row that gained `sharedMapRefusalReason` since Build 29 shipped.
final class StoredImportedLayerBuild29Tests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var databasePath: String { root.appendingPathComponent("library.sqlite").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredImportedLayerBuild29Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: databasePath)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A packet imported into a SQLite Library the way the app does it.
    private func importLayer(suggesting mode: ImportedCommentaryRevealMode?) throws -> ImportedCommentaryLayer {
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
        let revision = InterjectionShareRevision(
            id: "revision-1", interjectionId: "private-note", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-layer", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: mode
        )
        let url = root.appendingPathComponent("layer.spokenmargins")
        try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("layer-assets"))
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "recipient-item", localItem: item, itemText: "Before this passage. The durable idea that prompted this note. After this passage.",
            importedAt: created, repository: store
        )
        return try XCTUnwrap(try store.loadImportedCommentaryLayers(itemId: "recipient-item").first)
    }

    /// The payload the store wrote for a record, read straight from the SQLite file.
    private func storedPayload(kind: String, id: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM records WHERE kind = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(statement) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(statement, 0)!).hasSuffix(id) {
                return Data(String(cString: sqlite3_column_text(statement, 1)!).utf8)
            }
        }
        throw SessionKitError.persistenceFailed("no \(kind) record \(id)")
    }

    private func assertBuild29DecodesTheStoredLayer(
        _ layer: ImportedCommentaryLayer, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try store.saveImportedCommentaryLayer(layer)
        let payload = try storedPayload(kind: "imported_commentary_layer", id: layer.id)
        XCTAssertEqual(
            try ShippedPacketReader.decodeStoredRecord(kind: "imported_commentary_layer", payload: payload), layer.id,
            message, file: file, line: line
        )
        XCTAssertEqual(try store.quarantinedRecordCount(), 0, message, file: file, line: line)
    }

    func testBuild29DecodesTheLayerAsImported() throws {
        let layer = try importLayer(suggesting: .guided)
        XCTAssertEqual(layer.revealMode, .guided)
        try assertBuild29DecodesTheStoredLayer(layer, "an imported layer")
    }

    func testBuild29DecodesTheLayerWithEveryRevealModeThisBuildCanSave() throws {
        var layer = try importLayer(suggesting: nil)
        for mode in ImportedCommentaryRevealMode.allCases {
            layer.revealMode = mode
            try assertBuild29DecodesTheStoredLayer(layer, "reveal mode \(mode)")
        }
        layer.revealMode = nil
        try assertBuild29DecodesTheStoredLayer(layer, "no reveal mode")
    }

    func testBuild29DecodesTheLayerInEverySourceStatusAndWithTheMapRefusalThatCameAfterBuild29() throws {
        var layer = try importLayer(suggesting: .companion)
        // Written out by hand: ImportedSourceResolutionStatus is not CaseIterable. A case added to it has to be added here.
        let statuses: [ImportedSourceResolutionStatus] = [.pending, .resolved, .contextOnly, .ambiguous, .wrongSource, .unavailable]
        XCTAssertEqual(Set(statuses.map(\.rawValue)).count, 6)
        for status in statuses {
            layer.sourceResolutionStatus = status
            layer.sharedMapRefusalReason = status == .resolved ? nil : "The shared map did not fit this copy."
            try assertBuild29DecodesTheStoredLayer(layer, "source status \(status)")
        }
        let payload = String(decoding: try storedPayload(kind: "imported_commentary_layer", id: layer.id), as: UTF8.self)
        XCTAssertTrue(payload.contains("sharedMapRefusalReason"), "the field Build 29 has never seen is in the stored row")
    }

    func testBuild29DecodesALayerWithAMuteAndADeletedMarker() throws {
        var layer = try importLayer(suggesting: .fresh)
        layer.isMuted = true
        layer.isEnabled = false
        layer.deletedAt = created
        try assertBuild29DecodesTheStoredLayer(layer, "a muted, disabled, deleted layer")
    }
}
