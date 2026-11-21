import Foundation
import SQLite3
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4761: a read that has to cut or hash something keeps the result for next time. That cache write must never make the read
/// wait for another connection (a share or Safari extension) that holds SQLite's write lock. The store's own saves wait up
/// to its busy timeout for that lock; a cache write is skipped instead.
final class StoreCacheWriteDoesNotWaitTests: XCTestCase {
    /// Holds the write lock from a second connection, then runs `read` on its own thread. The store's busy timeout is
    /// 30 s, so a read that waits for the lock is still waiting at the 10 s ceiling this test allows, which is only a
    /// ceiling: a read that does not wait finishes in milliseconds and the test goes on at once.
    private func readWhileAnotherConnectionHoldsTheWriteLock(
        itemCount: Int = 3, _ read: @escaping @Sendable (SQLiteSessionStore) throws -> Void
    ) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cache-write-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        // No item is saved by `saveItem` with a kept slice, so every read below finds its slices and digests missing.
        for index in 1...itemCount {
            try store.saveItem(Item(id: "i\(index)", title: "Item \(index)", mediaType: "text", text: "Body \(index)",
                                    externalReference: nil, status: "ready"))
        }
        store.writeBusyTimeoutMs = 30_000
        sqlite3_busy_timeout(store.db, 30_000)

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK, "another connection holds the write lock")
        var released = false
        func release() {
            guard !released else { return }
            released = true
            sqlite3_exec(writer, "COMMIT", nil, nil, nil)
            sqlite3_close(writer)
        }
        defer { release() }

        let finished = expectation(description: "the read finished while the write lock was still held")
        let failure = LockedBox<Error?>(nil)
        Thread.detachNewThread {
            do { try read(store) } catch { failure.set(error) }
            finished.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [finished], timeout: 10)
        XCTAssertEqual(sqlite3_get_autocommit(writer), 0, "the other connection still held the write lock")
        release()   // lets a read that did wait come back, so the test ends either way
        XCTAssertEqual(outcome, .completed, "the read waited for the other connection's write lock")
        XCTAssertNil(failure.value)
        if outcome == .completed {
            // The write that was skipped still put the store's wait for saves back.
            XCTAssertEqual(busyTimeout(of: store), store.writeBusyTimeoutMs, "a save still waits for another connection's write lock")
        }
    }

    private func busyTimeout(of store: SQLiteSessionStore) -> Int32 {
        store.withConnectionLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(store.db, "PRAGMA busy_timeout;", -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
    }

    func testTheLibraryItemListDoesNotWaitForAnotherConnectionsWriteLock() throws {
        try readWhileAnotherConnectionHoldsTheWriteLock { store in
            let summaries = try store.listItemSummaries(includeDeleted: true)
            XCTAssertEqual(summaries.map(\.id).sorted(), ["i1", "i2", "i3"], "the items were read past the writer")
        }
    }

    func testItemArtworkKeysDoNotWaitForAnotherConnectionsWriteLock() throws {
        try readWhileAnotherConnectionHoldsTheWriteLock { store in
            XCTAssertEqual(try store.listItemArtworkKeys().count, 3)
        }
    }

    func testThePacketMatcherListDoesNotWaitForAnotherConnectionsWriteLock() throws {
        try readWhileAnotherConnectionHoldsTheWriteLock { store in
            let items = try store.listItemsForMatching(format: "test", needsDigests: { _ in true }, digests: { _ in ItemTextDigests(normalizedContentSHA256: "n", exactEditionSHA256: "e") })
            XCTAssertEqual(items.count, 3)
        }
    }

    /// With no writer holding the lock, the cache is still kept, and the busy timeout is back for the saves after it.
    func testTheCacheIsStillKeptAndTheSaveWaitIsRestored() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cache-write-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "i1", title: "One", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        _ = try store.listItemSummaries(includeDeleted: true)

        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(reader, "SELECT count(*) FROM records WHERE kind = '\(SQLiteSessionStore.itemSliceKind)';",
                                          -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1, "the slice was kept for the next read")

        XCTAssertEqual(busyTimeout(of: store), store.writeBusyTimeoutMs, "a save still waits for another connection's write lock")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
