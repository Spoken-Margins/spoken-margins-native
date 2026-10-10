import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The store has one SQLite connection shared by the main actor, the offline-storage ledger and
/// background jobs. SQLite's own full-mutex mode already serializes each single call, so the
/// connection lock only matters for work that spans several calls: a transaction
/// (`updateOwnedOfflineAsset`, `deleteOwnedOfflineAsset(id:if:)`, `deleteItems`, the quarantine
/// move inside a read) must keep other threads' statements out until it commits or rolls back.
/// Without that, another thread's save joins the open transaction on the same connection and a
/// rollback silently throws it away, although `save` returned success.
///
/// `testConcurrentReadsAndWritesShareOneConnectionSafely` only runs single-statement calls
/// (`saveOwnedOfflineAsset`, `loadOwnedOfflineAssets`, `listItems`), and the update tests are
/// sequential, so none of them can see the lock.
final class SQLiteConnectionLockTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-lock-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testASaveFromAnotherThreadWaitsUntilAnOpenTransactionIsFinished() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveOwnedOfflineAsset(asset("episode", bytes: 1))
        let insideTransaction = DispatchSemaphore(value: 0)
        let finishTransaction = DispatchSemaphore(value: 0)
        let saveReturned = Flag()
        let updateDone = DispatchSemaphore(value: 0)
        let saveDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            _ = try? store.updateOwnedOfflineAsset(id: "episode") { asset in
                asset.byteCount = 3
                insideTransaction.signal()
                _ = finishTransaction.wait(timeout: .now() + 10)
            }
            updateDone.signal()
        }
        XCTAssertEqual(insideTransaction.wait(timeout: .now() + 10), .success, "the update never started")
        Thread.detachNewThread {
            try? store.saveItem(Self.item("written-meanwhile"))
            saveReturned.set()
            saveDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.4)
        let returnedInsideTheTransaction = saveReturned.isSet
        finishTransaction.signal()
        XCTAssertEqual(updateDone.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(saveDone.wait(timeout: .now() + 10), .success)

        XCTAssertFalse(returnedInsideTheTransaction,
                       "saveItem ran on the shared connection while another thread's transaction was open")
        XCTAssertEqual(try store.loadOwnedOfflineAssets().first?.byteCount, 3)
        XCTAssertEqual(try store.loadItem(id: "written-meanwhile").id, "written-meanwhile")
    }

    func testASaveMadeWhileAnotherThreadsTransactionRollsBackIsNotLost() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveOwnedOfflineAsset(asset("episode", bytes: 1))
        try StoreRawSQL.execute("""
        CREATE TRIGGER refuse_poison BEFORE INSERT ON records
        WHEN NEW.kind = 'owned_offline_asset' AND NEW.id = 'poison'
        BEGIN SELECT RAISE(ABORT, 'refused for the test'); END;
        """, at: path)
        let insideTransaction = DispatchSemaphore(value: 0)
        let finishTransaction = DispatchSemaphore(value: 0)
        let updateFailed = Flag()
        let saveReturned = Flag()
        let updateDone = DispatchSemaphore(value: 0)
        let saveDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            do {
                _ = try store.updateOwnedOfflineAsset(id: "episode") { asset in
                    insideTransaction.signal()
                    _ = finishTransaction.wait(timeout: .now() + 10)
                    asset.id = "poison"
                }
            } catch {
                updateFailed.set()
            }
            updateDone.signal()
        }
        XCTAssertEqual(insideTransaction.wait(timeout: .now() + 10), .success, "the update never started")
        Thread.detachNewThread {
            do {
                try store.saveItem(Self.item("saved-during-rollback"))
                saveReturned.set()
            } catch {}
            saveDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        finishTransaction.signal()
        XCTAssertEqual(updateDone.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(saveDone.wait(timeout: .now() + 10), .success)

        XCTAssertTrue(updateFailed.isSet, "the trigger must have refused the update's save so that its transaction rolled back")
        XCTAssertTrue(saveReturned.isSet, "the save itself reported success")
        XCTAssertEqual(try store.listItems().map(\.id), ["saved-during-rollback"],
                       "a save that returned success was discarded by another thread's rollback")
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.byteCount), [1], "the rolled-back update left the asset as it was")
    }

    func testManyThreadsMixingTransactionsAndSavesLoseNothing() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveOwnedOfflineAsset(asset("counter", bytes: 0))
        for worker in 0..<8 { try store.saveOwnedOfflineAsset(asset("evictable-\(worker)", bytes: 1)) }
        let workers = 8
        let rounds = 25
        let failures = Failures()

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for round in 0..<rounds {
                do {
                    try store.updateOwnedOfflineAsset(id: "counter") { $0.byteCount += 1 }
                    try store.saveItem(Self.item("item-\(worker)-\(round)"))
                    if round == rounds - 1 {
                        _ = try store.deleteOwnedOfflineAsset(id: "evictable-\(worker)") { _ in true }
                    }
                } catch {
                    failures.add("worker \(worker) round \(round): \(error)")
                }
            }
        }

        XCTAssertEqual(failures.all, [])
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.id), ["counter"], "each worker's last round deleted its own evictable asset")
        XCTAssertEqual(try store.loadOwnedOfflineAssets().first?.byteCount, Int64(workers * rounds),
                       "every locked read-modify-write counted; a lost update leaves a smaller number")
        XCTAssertEqual(try store.listItems().count, workers * rounds)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    // MARK: Helpers

    private func asset(_ id: String, bytes: Int64) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: id, category: .preparedChunk, relativePath: id, byteCount: bytes, isReproducible: true)
    }

    private static func item(_ id: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: "Text of \(id).", externalReference: "manual-import", status: "ready")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return messages.sorted() }
}
