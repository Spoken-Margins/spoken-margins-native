import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// Starring, noting or deleting one Margin fixes its row instead of rebuilding the list (#2505).
final class MarginRowChangeTests: XCTestCase {
    private var fixture: LibraryFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func entries(_ store: SQLiteSessionStore) throws -> MarginCollection.Entries {
        try MarginCollection.build(
            items: store.listItems(), sessions: store.loadSessions(),
            loadInterjections: { try store.loadInterjections(sessionId: $0) },
            loadImportedLayers: { try store.loadImportedCommentaryLayers() },
            loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) })
    }

    func testTheChoiceForEachKindOfChange() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let active = try XCTUnwrap(entries(built.openStore()).privateRows.first).interjection
        XCTAssertEqual(active.status, "active")
        var deleted = active
        deleted.status = "deleted"
        XCTAssertEqual(MarginCollection.rowChange(saved: active, isListed: true), .update)
        XCTAssertEqual(MarginCollection.rowChange(saved: deleted, isListed: true), .remove)
        XCTAssertEqual(MarginCollection.rowChange(saved: deleted, isListed: false), .unchanged)
        XCTAssertEqual(MarginCollection.rowChange(saved: active, isListed: false), .rebuild, "a restored Margin is new to the list")
        XCTAssertEqual(MarginCollection.rowChange(saved: nil, isListed: true), .rebuild, "an unreadable Margin leaves the list to the full rebuild")
        XCTAssertEqual(MarginCollection.rowChange(saved: nil, isListed: false), .rebuild)
    }

    func testOneMarginsRowIsFixedFromOneSessionsMarginsAndMatchesAFullRebuild() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let meter = StoreReadMeter()
        let store = try built.openStore(meter: meter)
        let before = try entries(store).privateRows
        let rebuildRows = meter.totals(for: "loadInterjections(sessionId:)").rows
        let target = try XCTUnwrap(before.first)
        XCTAssertGreaterThan(before.count, 20, "a Library has many Margins")

        // Star it, as the app does: load the session's Margins, save the changed one.
        var starred = try XCTUnwrap(store.loadInterjections(sessionId: target.interjection.sessionId).first { $0.id == target.interjection.id })
        starred.isStarredForSharing = true
        try store.saveInterjection(starred)

        meter.reset()
        let saved = try store.loadInterjections(sessionId: target.interjection.sessionId).first { $0.id == target.interjection.id }
        let oneRead = meter.totals(for: "loadInterjections(sessionId:)")
        XCTAssertEqual(MarginCollection.rowChange(saved: saved, isListed: true), .update)
        XCTAssertEqual(oneRead.calls, 1)
        XCTAssertLessThan(oneRead.rows * 5, rebuildRows, "one session's Margins, not every session's (\(oneRead.rows) of \(rebuildRows) rows)")

        // The fixed row is the row a full rebuild gives.
        let fixed = before.map { $0.id == target.id
            ? MarginCollection.PrivateEntry(interjection: saved!, itemTitle: $0.itemTitle, sessionDate: $0.sessionDate, place: $0.place)
            : $0 }
        XCTAssertEqual(fixed, try entries(store).privateRows)

        // Delete it: the list without the row is the list a full rebuild gives.
        var gone = starred
        gone.status = "deleted"
        try store.saveInterjection(gone)
        let after = try store.loadInterjections(sessionId: target.interjection.sessionId).first { $0.id == target.interjection.id }
        XCTAssertEqual(MarginCollection.rowChange(saved: after, isListed: true), .remove)
        XCTAssertEqual(before.filter { $0.id != target.id }, try entries(store).privateRows)
    }
}
