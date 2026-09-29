import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

final class StructuredDocumentStoreTests: XCTestCase {
    private func document(version: Int, text: String) -> StructuredDocument {
        StructuredDocumentBuilder.build(
            lines: [StructuredDocumentLine(text: text, role: .body, pageIndex: 0)],
            engine: "pdfkit_baseline",
            version: version,
            pageCount: 1
        )
    }

    func testSQLiteKeepsEachExtractionVersionAndLoadsTheNewest() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: "Body two.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        try store.saveStructuredDocument(document(version: 2, text: "Body two."), itemId: item.id)
        try store.saveStructuredDocument(document(version: 3, text: "Body three."), itemId: item.id)

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadStructuredDocument(itemId: item.id)?.extraction.version, 3)
        XCTAssertNil(try reopened.loadStructuredDocument(itemId: "item-other"))
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5, "no schema change for Build 29 to check")

        try reopened.deleteItem(id: item.id)
        XCTAssertNil(try reopened.loadStructuredDocument(itemId: item.id), "deleting the item removes its documents")
    }

    func testInMemoryStoreLoadsTheNewestVersion() throws {
        let repo = InMemorySessionRepository()
        try repo.saveStructuredDocument(document(version: 3, text: "Three."), itemId: "item-a")
        try repo.saveStructuredDocument(document(version: 2, text: "Two."), itemId: "item-a")
        XCTAssertEqual(try repo.loadStructuredDocument(itemId: "item-a")?.text, "Three.")
    }
}
