import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: a caller that knows a reservation's id reads that one row, not every reservation.
final class OfflineStorageReservationByIdTests: XCTestCase {
    private func reservation(_ id: String, owner: String) -> OfflineStorageReservation {
        OfflineStorageReservation(id: id, ownerId: owner, byteCount: 10, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testReadsOnlyThatReservation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reservations-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let meter = StoreReadMeter()
        let store = try SQLiteSessionStore(path: path, readMeter: meter)
        for row in [reservation("r-1", owner: "podcast-download-a:1"), reservation("r-2", owner: "podcast-download-b:2"),
                    reservation("r-3", owner: "podcast-download-c:3")] {
            try store.saveOfflineStorageReservation(row)
        }

        meter.reset()
        let found = try store.loadOfflineStorageReservation(id: "r-2")
        let totals = meter.totals(for: "loadOfflineStorageReservation(id:)")

        XCTAssertEqual(found, try store.loadOfflineStorageReservations().first { $0.id == "r-2" })
        XCTAssertEqual(found?.ownerId, "podcast-download-b:2")
        XCTAssertEqual(totals.rows, 1, "the other reservations are not decoded")
        XCTAssertNil(try store.loadOfflineStorageReservation(id: "missing"))
    }

    func testADeletedReservationIsGone() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reservations-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        try store.saveOfflineStorageReservation(reservation("r-1", owner: "podcast-download-a:1"))
        try store.deleteOfflineStorageReservation(id: "r-1")
        XCTAssertNil(try store.loadOfflineStorageReservation(id: "r-1"))
    }
}
