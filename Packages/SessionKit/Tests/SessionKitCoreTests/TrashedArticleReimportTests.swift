import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Importing an article again that is sitting in Recently Deleted brings it back.
///
/// `testCorrectedReadableArticleCreatesSeparateEditionAndPreservesOriginalSession` (Mac-only target, in-memory
/// repository) trashes the corrected edition, imports it again and asserts only that the Item the import
/// returns has no `deletedAt`. That value is built in memory before the save: an import that returned the
/// restored Item but kept the stored one in the trash passed. The listener would see the article come back
/// once and then vanish. These tests read the item back from a real SQLite file, and check the Library lists.
final class TrashedArticleReimportTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-reimport-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    private func makeEngine() throws -> (SQLiteSessionStore, SessionEngine) {
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "browser", displayName: "Browser", capabilities: [
                "sync": ["browser_session_handoff", "canonical_persistence"],
            ]),
            repository: store
        )
        return (store, engine)
    }

    private func handoff(_ text: String) -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .readablePage, source: BrowserTextSource(url: "https://example.com/article", title: "Article"), text: text,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }

    func testImportingATrashedCorrectedArticleAgainRestoresTheStoredItemAndLeavesTheOriginalAlone() throws {
        let (store, engine) = try makeEngine()
        let original = try engine.importBrowserTextInBackground(handoff("A quote. A quote."))
        let corrected = try engine.importBrowserTextInBackground(handoff("A quote."))
        XCTAssertNotEqual(corrected.id, original.id, "fixture check: the corrected text is its own edition")
        try store.moveItemToTrash(id: corrected.id, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.listDeletedItems().map(\.id), [corrected.id], "fixture check: it is in Recently Deleted")
        let originalBefore = try store.loadItem(id: original.id)

        let again = try engine.importBrowserTextInBackground(handoff("A quote."))

        XCTAssertEqual(again.id, corrected.id)
        XCTAssertNil(try store.loadItem(id: corrected.id).deletedAt, "the stored item is out of the trash, not only the returned copy")
        XCTAssertEqual(try store.listItems().map(\.id).sorted(), [original.id, corrected.id].sorted())
        XCTAssertTrue(try store.listDeletedItems().isEmpty)
        XCTAssertEqual(try store.loadItem(id: original.id), originalBefore)
    }

    func testImportingATrashedArticleAgainRestoresTheStoredItem() throws {
        let (store, engine) = try makeEngine()
        let article = try engine.importBrowserTextInBackground(handoff("A quote. A quote."))
        try store.moveItemToTrash(id: article.id, at: Date(timeIntervalSince1970: 100))

        let again = try engine.importBrowserTextInBackground(handoff("A quote. A quote."))

        XCTAssertEqual(again.id, article.id)
        XCTAssertNil(try store.loadItem(id: article.id).deletedAt)
        XCTAssertEqual(try store.listItems().map(\.id), [article.id])
        XCTAssertTrue(try store.listDeletedItems().isEmpty)
    }

    func testTheAppsOwnImportAlsoRestoresATrashedArticleInTheStore() throws {
        let (store, engine) = try makeEngine()
        let article = try engine.importBrowserTextInBackground(handoff("A quote. A quote."))
        try store.moveItemToTrash(id: article.id, at: Date(timeIntervalSince1970: 100))

        _ = try engine.importBrowserText(handoff("A quote. A quote."))

        XCTAssertNil(try store.loadItem(id: article.id).deletedAt)
        XCTAssertEqual(try store.listItems().map(\.id), [article.id])
        XCTAssertTrue(try store.listDeletedItems().isEmpty)
    }
}
