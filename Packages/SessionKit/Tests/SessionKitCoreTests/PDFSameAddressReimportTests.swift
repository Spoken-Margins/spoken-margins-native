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
