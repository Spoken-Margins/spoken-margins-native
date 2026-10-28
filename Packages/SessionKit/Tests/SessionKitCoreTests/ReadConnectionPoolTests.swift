import Foundation
import XCTest
import SQLite3
@testable import SessionKitPersistence

/// #2818: the Library reads moved off the main thread (#2505, #2810) and ran side by side, so each store opened up to
/// six read connections and kept them all open. A full app test run, which leaves many stores alive, then ran out of
/// the 256 file descriptors iOS gives an app.
final class ReadConnectionPoolTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-read-pool-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES (1);", nil, nil, nil)
        sqlite3_close(db)
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        super.tearDown()
    }

    /// Descriptors open in this process. Only differences are compared, so the directory handle itself cancels out.
    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private func readOnce(_ connection: OpaquePointer) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(connection, "SELECT x FROM t", -1, &statement, nil)
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func testABurstOfReadersClosesDownToTheIdleLimitAndReleasesItsDescriptors() throws {
        let baseline = try openDescriptorCount()
        let pool = ReadConnectionPool(path: path, limit: 6, idleLimit: 2)
        let connections = (0..<6).compactMap { _ in pool.checkOut() }
        XCTAssertEqual(connections.count, 6)
        connections.forEach(readOnce) // a WAL reader opens its -shm on the first read
        XCTAssertEqual(pool.openConnectionCount, 6)
        let busy = try openDescriptorCount()
        XCTAssertGreaterThan(busy, baseline)

        connections.forEach(pool.checkIn)
        XCTAssertEqual(pool.openConnectionCount, 2, "only the idle limit stays open")
        let settled = try openDescriptorCount()
        XCTAssertLessThan(settled, busy, "the four extra readers gave their descriptors back")
        XCTAssertGreaterThan(settled, baseline, "the two idle readers are still open")

        pool.close()
        XCTAssertEqual(pool.openConnectionCount, 0)
        XCTAssertEqual(try openDescriptorCount(), baseline, "closing the pool leaves nothing open")
    }

    func testAReaderCheckedInAfterCloseIsClosedAndAWaiterIsNotStranded() throws {
        let pool = ReadConnectionPool(path: path, limit: 1, idleLimit: 1)
        let held = try XCTUnwrap(pool.checkOut())
        let got = expectation(description: "second reader gets a connection")
        let second = DispatchQueue.global()
        second.async {
            if let connection = pool.checkOut() { pool.checkIn(connection) }
            got.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        pool.checkIn(held)
        wait(for: [got], timeout: 5)
        pool.close()
        XCTAssertEqual(pool.openConnectionCount, 0)
    }
}
