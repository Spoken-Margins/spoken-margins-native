import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2062: a better PDF title must not make a re-import of the same PDF a second item. The id of a web or
/// share-sheet PDF is a slug of title and address, so the address has to find the item the old title made.
final class PDFSameAddressReimportTests: XCTestCase {
    private let address = "https://example.org/papers/attention.pdf"
    private let words = "We measured sleep in adults and found a steady effect."
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    func testReimportWithANewTitleReusesTheItemAndKeepsItsMargins() throws {
        let (store, engine) = try makeEngine()
        let old = try engine.importBrowserTextInBackground(handoff(title: "1 Introduction", url: address))
        try store.saveSession(session(for: old.id))
        let margin = Interjection(
            id: "m1", itemId: old.id, sessionId: "session-A", targetType: .item, targetId: old.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 3, endChar: 11, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "none", transcript: "Keep this", cleanedTranscript: "Keep this.", displayText: "Keep this", status: "active"
        )
        try store.saveInterjection(margin)

        let again = try engine.importBrowserTextInBackground(handoff(title: "Attention Is All You Need", url: address))

        XCTAssertEqual(again.id, old.id, "the same PDF from the same address is the same item")
        XCTAssertEqual(try store.listItems(includeDeleted: true).filter { $0.mediaType == "pdf" }.count, 1)
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A"), [margin])
    }

    func testReimportFindsAPDFTheListenerMovedToRecentlyDeleted() throws {
        let (store, engine) = try makeEngine()
        var old = try engine.importBrowserTextInBackground(handoff(title: "1 Introduction", url: address))
        old.deletedAt = Date()
        try store.saveItem(old)
        let again = try engine.importBrowserTextInBackground(handoff(title: "Attention Is All You Need", url: address))
        XCTAssertEqual(again.id, old.id)
        XCTAssertNil(try store.loadItem(id: old.id).deletedAt, "a re-import brings it back, as it does for the same title")
    }

    func testNeighbouringAddressesAreNotTheSamePDF() throws {
        let (store, engine) = try makeEngine()
        let first = try engine.importBrowserTextInBackground(handoff(title: "1 Introduction", url: address))
        for other in [
            "https://example.org/papers/attention.pdf?v=2",
            "https://example.org/papers/Attention.pdf",
            "https://example.com/papers/attention.pdf",
            "http://example.org/papers/attention.pdf",
            "shared-file://share-sheet/attention.pdf",
        ] {
            let item = try engine.importBrowserTextInBackground(handoff(title: "Attention Is All You Need", url: other))
            XCTAssertNotEqual(item.id, first.id, other)
        }
    }

    func testTwoLocalPDFsWithoutAWebAddressStayTwoItems() throws {
        let (_, engine) = try makeEngine()
        let one = try engine.importBrowserTextInBackground(handoff(title: "Notes", url: "shared-file://share-sheet/a.pdf"))
        let two = try engine.importBrowserTextInBackground(handoff(title: "Better Title", url: "shared-file://share-sheet/a.pdf"))
        XCTAssertNotEqual(one.id, two.id, "only an https address ties a new title to an old item; local files keep today's rule")
    }

    func testTheSameTitleStillMatchesBySlugAsBefore() throws {
        let (store, engine) = try makeEngine()
        let one = try engine.importBrowserTextInBackground(handoff(title: "Attention", url: address))
        let two = try engine.importBrowserTextInBackground(handoff(title: "Attention", url: address))
        XCTAssertEqual(one.id, two.id)
        XCTAssertEqual(try store.listItems(includeDeleted: true).filter { $0.mediaType == "pdf" }.count, 1)
    }

    func testATitleWithTheWordEditionIsStillFound() throws {
        let (store, engine) = try makeEngine()
        let old = try engine.importBrowserTextInBackground(handoff(title: "Annual Report Edition 2024", url: address))
        XCTAssertTrue(old.id.contains("-edition-"), "the slug itself contains the word")
        let again = try engine.importBrowserTextInBackground(handoff(title: "Annual Report 2024", url: address))
        XCTAssertEqual(again.id, old.id)
        XCTAssertEqual(try store.listItems(includeDeleted: true).filter { $0.mediaType == "pdf" }.count, 1)
    }

    /// Changed text still becomes its own edition, as it does for a same-title re-import: Margin anchors index the
    /// old words, so the original item keeps them. This pins that a new title does not change that rule.
    func testChangedTextWithANewTitleMakesAnEditionOfTheOriginalItem() throws {
        let (store, engine) = try makeEngine()
        let old = try engine.importBrowserTextInBackground(handoff(title: "1 Introduction", url: address))
        let revised = BrowserTextHandoff(
            captureMode: .markdownFile, source: .init(url: address, title: "Attention Is All You Need"),
            text: words + " A new paragraph.", contentFormat: .plainText
        )
        let again = try engine.importBrowserTextInBackground(revised)
        XCTAssertTrue(again.id.hasPrefix(old.id + "-edition-"), again.id)
        XCTAssertEqual(try store.loadItem(id: old.id).text, words)
    }

    /// The app imports a PDF with a structured document, which can move an unplayed item with no Margins to new
    /// text in place. An item found only by its address may be a different PDF now served there (a newsletter's
    /// "current.pdf"), so it is never overwritten: the new text becomes an edition and the old text stays.
    @MainActor
    func testADifferentPDFAtTheSameAddressBecomesAnEditionNotAnOverwrite() async throws {
        for offMain in [false, true] {
            let (store, engine) = try makeEngine()
            let spring = newsletter("Spring Newsletter", body: "Spring planting starts in April. Bring seeds to the hall.")
            let old = try engine.importBrowserTextInBackground(documentHandoff(spring), structuredDocument: spring)
            let summer = newsletter("Summer Newsletter", body: "The summer picnic is in July. Bring a dish to share.")
            let again = offMain
                ? try await engine.importBrowserTextInBackgroundOffMain(documentHandoff(summer), structuredDocument: summer)
                : try engine.importBrowserTextInBackground(documentHandoff(summer), structuredDocument: summer)

            XCTAssertTrue(again.id.hasPrefix(old.id + "-edition-"), "offMain \(offMain): \(again.id)")
            let kept = try store.loadItem(id: old.id)
            XCTAssertEqual(kept.text, spring.text, "offMain \(offMain)")
            XCTAssertEqual(kept.title, "Spring Newsletter", "offMain \(offMain)")
            XCTAssertEqual(try store.loadStructuredDocument(itemId: old.id), spring, "offMain \(offMain)")
            XCTAssertEqual(try store.loadItem(id: again.id).text, summer.text, "offMain \(offMain)")
        }
    }

    /// The same PDF read again under its new title, with unchanged text, is still the one item.
    @MainActor
    func testTheSamePDFWithADocumentAndANewTitleIsStillOneItem() async throws {
        let (store, engine) = try makeEngine()
        let paper = newsletter("1 Introduction", body: "We measured sleep in adults and found a steady effect.")
        let old = try engine.importBrowserTextInBackground(documentHandoff(paper), structuredDocument: paper)
        let retitled = BrowserTextHandoff(
            captureMode: .markdownFile, source: .init(url: address, title: "Attention Is All You Need"),
            text: paper.text, contentFormat: .plainText
        )
        let again = try await engine.importBrowserTextInBackgroundOffMain(retitled, structuredDocument: paper)
        XCTAssertEqual(again.id, old.id)
        XCTAssertEqual(try store.listItems(includeDeleted: true).filter { $0.mediaType == "pdf" }.count, 1)
    }

    private func newsletter(_ title: String, body: String) -> StructuredDocument {
        StructuredDocumentBuilder.build(lines: [
            .init(text: title, role: .title, pageIndex: 0),
            .init(text: body, role: .body, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
    }

    private func documentHandoff(_ document: StructuredDocument) -> BrowserTextHandoff {
        let title = document.text.components(separatedBy: "\n").first ?? ""
        return .init(captureMode: .markdownFile, source: .init(url: address, title: title), text: document.text, contentFormat: .plainText)
    }

    func testSeveralOriginalsAtOneAddressPickTheListenersOldestCopy() throws {
        let (store, engine) = try makeEngine()
        func original(_ id: String, created: TimeInterval, deleted: Bool) -> Item {
            var item = Item(id: id, title: id, mediaType: "pdf", text: words, externalReference: address, status: "ready",
                            createdAt: Date(timeIntervalSince1970: created))
            if deleted { item.deletedAt = Date() }
            return item
        }
        try store.saveItem(original("item-browser-trash", created: 1, deleted: true))
        try store.saveItem(original("item-browser-newer", created: 20, deleted: false))
        try store.saveItem(original("item-browser-older", created: 10, deleted: false))
        let again = try engine.importBrowserTextInBackground(handoff(title: "Attention Is All You Need", url: address))
        XCTAssertEqual(again.id, "item-browser-older")
    }

    private func handoff(title: String, url: String) -> BrowserTextHandoff {
        .init(captureMode: .markdownFile, source: .init(url: url, title: title), text: words, contentFormat: .plainText)
    }

    private func makeEngine() throws -> (SQLiteSessionStore, SessionEngine) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-pdf-address-\(UUID().uuidString).sqlite").path
        paths.append(path)
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        return (store, engine)
    }

    private func session(for itemId: String) -> Session {
        Session(
            id: "session-A", itemId: itemId, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: itemId, position: Position(), completionPercent: 0, playbackRate: 1
        )
    }
}
