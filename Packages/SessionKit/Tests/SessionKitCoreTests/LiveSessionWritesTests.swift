import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A live session saves its text item and Margins off the main actor (#2509), against real SQLite.
final class LiveSessionWritesTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-writes-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func textItem(_ id: String = "item-live-1", text: String = "First line.\n\nSecond line.") -> Item {
        Item(id: id, title: "Notes", mediaType: "text", text: text, externalReference: "live-session",
             status: "needs_listening_map", externalReferenceType: "manual", createdAt: Date(timeIntervalSince1970: 1))
    }

    private let margins = [
        LiveSessionAlignment.Placed(id: "b", text: "Two", offsetMs: 0, charOffset: 13),
        LiveSessionAlignment.Placed(id: "a", text: "One", offsetMs: 0, charOffset: 0),
    ]

    func testTheTextItemAndItsMarginsAreInTheStoreWhenTheReadReturns() async throws {
        let store = try makeStore()
        let item = textItem()
        let placed = margins

        let linked = try await StoreReader(store).readInOrder(LiveSessionWrites.orderKey) { try LiveSessionWrites.saveTextItem(item, placed: placed, in: $0) }

        XCTAssertEqual(linked.map(\.liveId), ["a", "b"], "each Margin is paired with the live Margin it came from, in text order")
        XCTAssertEqual(try store.loadItem(id: item.id).text, item.text)
        XCTAssertEqual(try store.loadItem(id: item.id).status, "needs_listening_map")
        let sessions = try store.loadSessions(itemId: item.id)
        XCTAssertEqual(sessions.count, 1)
        let stored = try store.loadInterjections(sessionId: try XCTUnwrap(sessions.first).id)
        XCTAssertEqual(Set(stored.compactMap(\.displayText)), ["One", "Two"])
        XCTAssertEqual(Set(stored.map(\.id)), Set(linked.map(\.saved.id)))
    }

    func testASessionWithNoMarginsStillSavesItsItemAndAnEmptySession() throws {
        let store = try makeStore()
        let linked = try LiveSessionWrites.saveTextItem(textItem(), placed: [], in: store)
        XCTAssertTrue(linked.isEmpty)
        XCTAssertNoThrow(try store.loadItem(id: "item-live-1"))
        XCTAssertEqual(try store.loadSessions(itemId: "item-live-1").count, 1)
    }

    /// An item with no text can't hold a Margin: placing throws, and the item stays saved as it did on the main thread.
    func testAnItemWithNothingToAnchorToThrowsAndKeepsTheSavedItem() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try LiveSessionWrites.saveTextItem(textItem(text: ""), placed: margins, in: store)) {
            XCTAssertEqual($0 as? LiveSessionMarginPlacer.Failure, .notAudio)
        }
        XCTAssertNoThrow(try store.loadItem(id: "item-live-1"))
    }
}
