import Foundation
import SQLite3
@testable import SessionKit
@testable import SessionKitPersistence
@testable import SessionKitSharing
import XCTest

/// #3409: repairing a friend's packet onto a new item is one transaction, on a real SQLite file. The failures are
/// real SQLite errors (a trigger on the file, set up on a second connection), not a fake repository that throws.
final class ImportedLayerRepairTransactionTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!
    private var store: SQLiteSessionStore!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let identity = SharedItemIdentity(itemType: .other, title: "Book", durationMs: 10_000, exactEditionSHA256: String(repeating: "a", count: 64))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("repair-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: databasePath)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testARepairThatFailsOnTheSecondMarginLeavesNothingHalfSaved() throws {
        try seedLayerWithTwoMargins()
        try runSQL("""
            CREATE TRIGGER refuse_second_margin BEFORE INSERT ON records
            WHEN NEW.kind = 'imported_commentary_interjection' AND NEW.id = 'margin-b'
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """)
        let before = try snapshot()

        XCTAssertThrowsError(try repair())

        XCTAssertEqual(try snapshot(), before, "the layer is still on the old item and no Margin was re-resolved")
        XCTAssertEqual(try store.loadImportedCommentaryLayer(id: "layer")?.itemId, "old-item")
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "layer").count, 2)
    }

    func testARepairThatSucceedsMovesTheLayerAndReResolvesEveryMargin() throws {
        try seedLayerWithTwoMargins()

        try repair()

        XCTAssertEqual(try store.loadImportedCommentaryLayer(id: "layer")?.itemId, "new-item")
        let margins = try store.loadImportedCommentaryInterjections(layerId: "layer").sorted { $0.id < $1.id }
        XCTAssertEqual(margins.map(\.id), ["margin-a", "margin-b"])
        XCTAssertEqual(margins.map(\.audioPath), ["/kept/a.m4a", "/kept/b.m4a"], "the voices keep their files")
        XCTAssertEqual(margins[0].resolution.evidenceClass, .exactEdition)
        XCTAssertEqual(margins[1].resolution.evidenceClass, .unresolved, "a Margin the packet doesn't carry falls back")
    }

    func testARepairAfterAPermanentDeleteTookTheLayerThrowsAndBringsNothingBack() throws {
        try seedLayerWithTwoMargins()
        let stale = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        try store.deleteItem(id: "old-item")
        XCTAssertNil(try store.loadImportedCommentaryLayer(id: "layer"))

        XCTAssertThrowsError(try repair(existing: stale)) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_package_repair_layer_is_gone"))
        }

        XCTAssertNil(try store.loadImportedCommentaryLayer(id: "layer"), "the stale copy is not saved back")
        XCTAssertTrue(try store.loadImportedCommentaryInterjections(layerId: "layer").isEmpty)
    }

    func testARepairInsideAnotherTransactionJoinsItAndRollsBackWithIt() throws {
        try seedLayerWithTwoMargins()
        struct Abandon: Error {}
        let before = try snapshot()

        XCTAssertThrowsError(try store.withSessionTransaction {
            try repair()
            XCTAssertEqual(try store.loadImportedCommentaryLayer(id: "layer")?.itemId, "new-item", "visible inside the transaction")
            throw Abandon()
        })

        XCTAssertEqual(try snapshot(), before, "no deadlock joining it, and nothing of the repair survives")
    }

    func testAWriteFromAnotherThreadWaitsForTheRepairAndThenSucceeds() throws {
        try seedLayerWithTwoMargins()
        let finished = DispatchSemaphore(value: 0)
        let failure = Failure()
        DispatchQueue.global().async { [store] in
            do { try store?.saveItem(Item(id: "other", title: "Other", mediaType: "text", text: "x", externalReference: nil, status: "ready")) }
            catch { failure.error = error }
            finished.signal()
        }
        try repair()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "a writer on another thread is never left waiting")
        XCTAssertNil(failure.error)
    }

    // MARK: Fixtures

    private final class Failure: @unchecked Sendable { var error: Error? }

    private func repair(existing: ImportedCommentaryLayer? = nil) throws {
        let layer = try existing ?? XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        try SpokenMarginsPackageImporter.repairAssociation(
            existing: layer, contents: makeContents(), itemId: "new-item", localItem: identity,
            itemText: nil, repository: store)
    }

    private func seedLayerWithTwoMargins() throws {
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: "layer", itemId: "old-item", packageDigest: "packet-digest", packageId: "packet",
            itemIdentity: identity, displayLabel: "Friend", importedAt: date,
            sourceResolutionStatus: .contextOnly, isEnabled: true, isMuted: false))
        for (id, scoped, path) in [("margin-a", "in-packet", "/kept/a.m4a"), ("margin-b", "not-in-packet", "/kept/b.m4a")] {
            try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
                id: id, layerId: "layer", packageScopedId: scoped, createdAt: date,
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
                approvedTranscript: "Keep this thought", audioPath: path, audioDurationMs: 500,
                resolution: ImportedAnchorResolution(evidenceClass: .timestampFallback)))
        }
    }

    /// Every imported row as stored, so "nothing half saved" compares bytes, not a few fields.
    private func snapshot() throws -> [String] {
        try rows("SELECT kind || '|' || id || '|' || COALESCE(item_id, '') || '|' || payload FROM records WHERE kind LIKE 'imported_commentary%' ORDER BY kind, id;")
    }

    private func makeContents() -> VerifiedSpokenMarginsPackage {
        let record = SharedInterjectionPackageRecord(packageScopedId: "in-packet", createdAt: date,
            anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), defaultRepresentationId: "text",
            representations: [.init(id: "text", kind: .textOnly, approvedTranscript: "Keep this thought", provenance: .senderApprovedTextOnly)])
        return VerifiedSpokenMarginsPackage(
            manifest: SpokenMarginsPackageManifest(packageId: "packet", createdAt: date, contentDigest: "packet-digest",
                item: identity, itemTransport: .init(kind: .recipientSupplied), artifacts: []),
            commentaryLayers: [.init(id: "commentary", interjections: [record])],
            listeningMapProposals: [], editionFingerprintSpines: [], transcriptPhraseSketches: [], embeddedTextItems: [],
            extractedAssetURLs: [:])
    }

    private func runSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func rows(_ sql: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("open")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
        return result
    }
}
