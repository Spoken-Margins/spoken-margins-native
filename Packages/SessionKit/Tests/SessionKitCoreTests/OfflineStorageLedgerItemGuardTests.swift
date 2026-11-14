import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #4227: an episode-map run writes ledger rows for its item over a long step. A permanent delete that lands while it
/// works must not get a `fingerprintMap` or `transientEpisodeTranscript` row (or its file) written back for an item that
/// is gone. Real SQLite store and real temporary files.
final class OfflineStorageLedgerItemGuardTests: XCTestCase {
    private var base: URL!
    private var store: SQLiteSessionStore!
    private var ledger: OfflineStorageLedger!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory.appending(path: "ledger-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        ledger = OfflineStorageLedger(repository: store, rootDirectory: base)
    }

    override func tearDownWithError() throws {
        ledger = nil
        store = nil
        try? manager.removeItem(at: base)
    }

    private func saveItem(_ id: String) throws {
        try store.saveItem(Item(id: id, title: id, mediaType: "audio", text: "Body", externalReference: nil, status: "ready"))
    }

    /// A reservation and the file the writer made under it, as an episode-map run leaves them just before its commit.
    private func writtenAsset(itemId: String?, name: String = "landmark.shazamsignature") async throws
        -> (reservation: OfflineStorageReservation, asset: OwnedOfflineAsset, file: URL) {
        let relative = "SpokenMargins/EpisodeMaps/\(itemId ?? "none")/\(name)"
        let file = base.appending(path: relative)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("landmark".utf8).write(to: file)
        let reservation = try await ledger.reserve(ownerId: "episode-fingerprint-\(itemId ?? "none")", byteCount: 1_024)
        let asset = OwnedOfflineAsset(
            id: "asset-\(name)", itemId: itemId, category: .fingerprintMap, relativePath: relative,
            byteCount: 8, isReproducible: true, protections: [.activeEpisodeMapPreparation]
        )
        return (reservation, asset, file)
    }

    func testAnItemThatStillExistsGetsItsRowAndKeepsItsFile() async throws {
        try saveItem("alive")
        let written = try await writtenAsset(itemId: "alive")

        let committed = try await ledger.commitIfItemExists(reservationId: written.reservation.id, asset: written.asset)

        XCTAssertTrue(committed)
        XCTAssertEqual(try store.loadOwnedOfflineAssets(itemId: "alive").map(\.id), [written.asset.id])
        XCTAssertTrue(manager.fileExists(atPath: written.file.path))
        XCTAssertTrue(try store.loadOfflineStorageReservations().isEmpty, "the reservation is spent")
    }

    /// The bug: before, `commit` saved the row whether or not the item was still there.
    func testADeleteBeforeTheCommitLeavesNoRowNoReservationAndNoFile() async throws {
        try saveItem("doomed")
        let written = try await writtenAsset(itemId: "doomed")
        try store.deleteItem(id: "doomed")

        let committed = try await ledger.commitIfItemExists(reservationId: written.reservation.id, asset: written.asset)

        XCTAssertFalse(committed)
        XCTAssertTrue(try store.loadOwnedOfflineAssets().isEmpty, "no row for an item that is gone")
        XCTAssertTrue(try store.loadOfflineStorageReservations().isEmpty, "the reservation is released")
        XCTAssertFalse(manager.fileExists(atPath: written.file.path), "the file the run made is removed")
    }

    func testAPlainCommitStillSavesTheRow() async throws {
        // The guard is opt-in: importers commit an asset before their item row exists.
        let written = try await writtenAsset(itemId: "not-saved-yet")
        try await ledger.commit(reservationId: written.reservation.id, asset: written.asset)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.id), [written.asset.id])
    }

    func testAnAssetWithNoItemCommitsAsBefore() async throws {
        let written = try await writtenAsset(itemId: nil)
        let committed = try await ledger.commitIfItemExists(reservationId: written.reservation.id, asset: written.asset)
        XCTAssertTrue(committed)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.id), [written.asset.id])
    }

    func testAFileAnotherRowStillOwnsSurvivesARefusedCommit() async throws {
        // A refused commit removes only what nothing else records: a non-reproducible row for the same path keeps it.
        try saveItem("doomed")
        let written = try await writtenAsset(itemId: "doomed")
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "keeper", itemId: nil, category: .audiobook, relativePath: written.asset.relativePath,
            byteCount: 8, isReproducible: false
        ))
        try store.deleteItem(id: "doomed")

        let committed = try await ledger.commitIfItemExists(reservationId: written.reservation.id, asset: written.asset)

        XCTAssertFalse(committed)
        XCTAssertTrue(manager.fileExists(atPath: written.file.path))
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.id), ["keeper"])
    }

    func testTheCheckIsPerItem() async throws {
        try saveItem("alive")
        try saveItem("doomed")
        try store.deleteItem(id: "doomed")
        let a = try await writtenAsset(itemId: "alive", name: "a.shazamsignature")
        let d = try await writtenAsset(itemId: "doomed", name: "d.shazamsignature")

        let aliveCommitted = try await ledger.commitIfItemExists(reservationId: a.reservation.id, asset: a.asset)
        let doomedCommitted = try await ledger.commitIfItemExists(reservationId: d.reservation.id, asset: d.asset)

        XCTAssertTrue(aliveCommitted)
        XCTAssertFalse(doomedCommitted)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.id), [a.asset.id])
    }
}
