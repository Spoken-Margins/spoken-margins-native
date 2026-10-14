import Foundation
import XCTest
@testable import SessionKit

private final class PlanningFailureRepository: InMemorySessionRepository, @unchecked Sendable {
    var failNextRead = false
    var sawReadOffMain = false
    override func loadInterjections(sessionId: String) throws -> [Interjection] {
        if failNextRead {
            failNextRead = false
            sawReadOffMain = !Thread.isMainThread
            throw SessionKitError.persistenceFailed("injected_planning_read_failure")
        }
        return try super.loadInterjections(sessionId: sessionId)
    }
}

final class PDFPlanningFailureTests: XCTestCase {
    private func setup() throws -> (PlanningFailureRepository, SessionEngine, Item, BrowserTextHandoff, StructuredDocument) {
        let store = PlanningFailureRepository()
        let engine = SessionEngine(profile: .init(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let source = BrowserTextSource(url: "shared-file://Paper.pdf", title: "Paper")
        let old = try engine.importBrowserTextInBackground(.init(captureMode: .markdownFile, source: source, text: "Original body.", contentFormat: .plainText))
        try store.saveSession(.init(id: "session", itemId: old.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: old.id, position: .init(), completionPercent: 0, playbackRate: 1))
        let document = StructuredDocumentBuilder.build(lines: [.init(text: "Revised body.", role: .body, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let handoff = BrowserTextHandoff(captureMode: .markdownFile, source: source, text: document.text, contentFormat: .plainText)
        store.failNextRead = true
        return (store, engine, old, handoff, document)
    }

    func testPlanningErrorImportsASeparateEditionSynchronously() throws {
        let (store, engine, old, handoff, document) = try setup()
        let imported = try engine.importBrowserTextInBackground(handoff, structuredDocument: document)
        XCTAssertNotEqual(imported.id, old.id)
        XCTAssertEqual(try store.loadItem(id: old.id), old)
        XCTAssertEqual(try store.listItems().count, 2)
        XCTAssertEqual(try store.loadStructuredDocument(itemId: imported.id), document)
    }

    @MainActor
    func testPlanningErrorImportsASeparateEditionOffMain() async throws {
        let (store, engine, old, handoff, document) = try setup()
        let imported = try await engine.importBrowserTextInBackgroundOffMain(handoff, structuredDocument: document)
        XCTAssertTrue(store.sawReadOffMain, "the actual failed planning read happened away from the UI thread")
        XCTAssertNotEqual(imported.id, old.id)
        XCTAssertEqual(try store.loadItem(id: old.id), old)
        XCTAssertEqual(try store.listItems().count, 2)
        XCTAssertEqual(try store.loadStructuredDocument(itemId: imported.id), document)
    }
}
