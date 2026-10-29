import Foundation
import XCTest
@testable import SessionKit

/// Records the thread of every store call an import makes, so a test can say none was on the main thread.
private final class ThreadRecordingRepository: InMemorySessionRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var mainCalls: [String] = []
    var recording = false

    func startRecording() { lock.lock(); recording = true; calls = []; mainCalls = []; lock.unlock() }
    var mainThreadCalls: [String] { lock.lock(); defer { lock.unlock() }; return mainCalls }
    var allCalls: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    private func note(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        calls.append(name)
        if Thread.isMainThread { mainCalls.append(name) }
    }

    override func loadItem(id: String) throws -> Item { note("loadItem"); return try super.loadItem(id: id) }
    override func saveItem(_ item: Item) throws { note("saveItem"); try super.saveItem(item) }
    override func listItems(includeDeleted: Bool = false) throws -> [Item] { note("listItems"); return try super.listItems(includeDeleted: includeDeleted) }
    override func loadListeningMap(itemId: String) throws -> ListeningMap? { note("loadListeningMap"); return try super.loadListeningMap(itemId: itemId) }
    override func saveListeningMap(_ map: ListeningMap) throws { note("saveListeningMap"); try super.saveListeningMap(map) }
}

/// A browser-text or file import reads what is there, and writes the item, its map and its document, off the main
/// thread (#2509). The engine still ends in the state the synchronous import gives.
final class BrowserTextImportOffMainTests: XCTestCase {
    private func makeEngine() -> (ThreadRecordingRepository, SessionEngine) {
        let store = ThreadRecordingRepository()
        let engine = SessionEngine(
            profile: .init(id: "import", displayName: "Import", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        return (store, engine)
    }

    private let markdown = "# Field notes\n\n## Morning\n\nThe light came early.\n\n## Evening\n\nIt faded slowly.\n"

    @MainActor
    func testAnImportedFileIsReadAndWrittenOffTheMainThread() async throws {
        let (store, engine) = makeEngine()
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://notes.md", title: "notes"),
            text: markdown,
            contentFormat: .markdown
        )
        store.startRecording()

        let item = try await engine.importBrowserTextInBackgroundOffMain(handoff)

        XCTAssertTrue(store.allCalls.contains("saveItem"), "fixture check: the import wrote the item")
        XCTAssertTrue(store.allCalls.contains("saveListeningMap"), "fixture check: the import wrote its map")
        XCTAssertEqual(store.mainThreadCalls, [], "a store call ran on the main thread during the import")
        XCTAssertEqual(try store.loadItem(id: item.id), item)
        XCTAssertNotNil(try store.loadListeningMap(itemId: item.id))
    }

    @MainActor
    func testAnImportedPDFWritesItsDocumentOffTheMainThread() async throws {
        let (store, engine) = makeEngine()
        let document = StructuredDocumentBuilder.build(
            lines: [.init(text: "Revised body.", role: .body, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1
        )
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://Paper.pdf", title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        )
        store.startRecording()

        let item = try await engine.importBrowserTextInBackgroundOffMain(handoff, structuredDocument: document)

        XCTAssertEqual(store.mainThreadCalls, [], "a store call ran on the main thread during the import")
        XCTAssertEqual(try store.loadStructuredDocument(itemId: item.id), document)
        XCTAssertEqual(item.mediaType, "pdf")
    }

    /// The off-main import and the synchronous one store the same rows.
    @MainActor
    func testTheOffMainImportStoresWhatTheSynchronousImportStores() async throws {
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://notes.md", title: "notes"),
            text: markdown,
            contentFormat: .markdown
        )
        let (syncStore, syncEngine) = makeEngine()
        let syncItem = try syncEngine.importBrowserTextInBackground(handoff)
        let (asyncStore, asyncEngine) = makeEngine()
        let asyncItem = try await asyncEngine.importBrowserTextInBackgroundOffMain(handoff)

        XCTAssertEqual(asyncItem.id, syncItem.id)
        XCTAssertEqual(asyncItem.text, syncItem.text)
        XCTAssertEqual(try asyncStore.loadListeningMap(itemId: asyncItem.id), try syncStore.loadListeningMap(itemId: syncItem.id))
    }

    /// Importing the same page again keeps one row; a different extraction of an open item is its own edition.
    @MainActor
    func testReimportingAnOpenItemWithNewTextMakesAnEditionOffMain() async throws {
        let (store, engine) = makeEngine()
        let source = BrowserTextSource(url: "https://example.com/post", title: "A post")
        let first = try await engine.importBrowserTextInBackgroundOffMain(
            BrowserTextHandoff(captureMode: .readablePage, source: source, text: "One paragraph of the post.", contentFormat: .plainText)
        )
        _ = try engine.startSession(itemId: first.id)
        store.startRecording()

        let second = try await engine.importBrowserTextInBackgroundOffMain(
            BrowserTextHandoff(captureMode: .readablePage, source: source, text: "A corrected paragraph of the post.", contentFormat: .plainText)
        )

        XCTAssertEqual(store.mainThreadCalls, [])
        XCTAssertNotEqual(second.id, first.id, "the open item keeps its text; the new text is its own edition")
        XCTAssertEqual(try store.loadItem(id: first.id).text, "One paragraph of the post.")
        XCTAssertEqual(try store.listItems().count, 2)
    }
}
