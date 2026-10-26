import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: the Export Sessions list builds its rows through `StoreReader`, off the main actor.
final class BatchExportRowsTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func openFixtureStore() throws -> SQLiteSessionStore {
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        return try fixture.openStore()
    }

    /// The rows are what the model built inline before: every session whose item exists, with its item's title and
    /// its active Margin count (zero when it has none).
    func testRowsPairEverySessionWithItsItemTitleAndActiveMarginCount() throws {
        let store = try openFixtureStore()
        let titles = Dictionary(uniqueKeysWithValues: try store.listItems().map { ($0.id, $0.title) })
        let sessions = try store.loadSessions()

        let rows = try store.loadBatchExportRows()

        XCTAssertEqual(rows.map(\.id), sessions.map(\.id), "one row per session, in the store's session order")
        for row in rows {
            XCTAssertEqual(row.itemTitle, titles[row.session.itemId])
            let active = try store.loadInterjections(sessionId: row.id).filter { $0.status == "active" }.count
            XCTAssertEqual(row.interjectionCount, active, row.id)
        }
        XCTAssertTrue(rows.contains { $0.interjectionCount == 0 }, "a session with no Margins still has a row")
        XCTAssertTrue(rows.contains { $0.interjectionCount > 0 })
    }

    func testASessionWhoseItemIsGoneHasNoRow() throws {
        let store = try openFixtureStore()
        let before = try store.loadBatchExportRows()
        let victim = try XCTUnwrap(before.first)
        var orphan = victim.session
        orphan.id = "session-orphan"
        orphan.itemId = "item-that-never-existed"
        try store.saveSession(orphan)

        let after = try store.loadBatchExportRows()

        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertFalse(after.contains { $0.id == "session-orphan" })
    }

    /// The boundary (#2507): while the rows are being built, the main actor keeps running. The slow store is a
    /// blocked read in the same `StoreReader` closure, standing in for a Library-size read.
    @MainActor
    func testBuildingTheRowsThroughTheReaderDoesNotBlockTheMainActor() async throws {
        let store = try openFixtureStore()
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let rows = try await StoreReader(store).read { store -> [BatchSessionExportRow] in
            Thread.sleep(forTimeInterval: 0.3)
            return try store.loadBatchExportRows()
        }
        ticker.cancel()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertGreaterThan(ticks, 5, "the main actor kept running while the read was slow (a blocked read gives 1)")
    }
}
