import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The trash, restore, permanent-delete and "does this item still exist" paths read an item's summary, not its text
/// (#2506). They lean on three things the summary has to answer exactly as the whole item did: a trashed item still
/// answers (with `deletedAt`), an item that is gone answers nil even when a summary was cut before it went, and
/// `hasListenableText` is the old "text with something besides whitespace" test.
final class TrashFlowSummaryReadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-trash-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openStore(with items: [Item]) throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        for item in items { try store.saveItem(item) }
        return store
    }

    private func article(_ id: String, text: String? = String(repeating: "A long article. ", count: 2_000)) -> Item {
        Item(id: id, title: "Title of \(id)", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    func testATrashedItemStillAnswersWithItsTitleAndDeletedAtAndARestoredOneDoesNot() throws {
        let store = try openStore(with: [article("a"), article("b")])
        _ = try store.listItemSummaries() // cut and stored before the trash

        try store.moveItemToTrash(id: "a")
        let trashed = try XCTUnwrap(try store.loadItemSummary(id: "a"))
        XCTAssertEqual(trashed.title, "Title of a")
        XCTAssertNotNil(trashed.deletedAt)
        XCTAssertNil(try store.loadItemSummary(id: "b")?.deletedAt)

        try store.restoreItem(id: "a")
        XCTAssertNil(try store.loadItemSummary(id: "a")?.deletedAt)
    }

    func testAnItemThatIsDeletedAnswersNilEvenAfterASummaryWasCutForIt() throws {
        let store = try openStore(with: [article("a"), article("b"), article("c")])
        _ = try store.listItemSummaries()
        try store.moveItemToTrash(id: "a")
        _ = try store.listItemSummaries(includeDeleted: true)

        try store.deleteItem(id: "a")
        try store.deleteItems(ids: ["b", "c"])

        for id in ["a", "b", "c"] {
            XCTAssertNil(try store.loadItemSummary(id: id), "permanent delete checks that \(id) is gone this way")
        }
        XCTAssertThrowsError(try store.loadItem(id: "a"), "the whole-item read says the same")
    }

    func testAnUnknownIdAnswersNilWhereTheWholeReadThrows() throws {
        let store = try openStore(with: [article("a")])
        XCTAssertNil(try store.loadItemSummary(id: "nope"))
        XCTAssertThrowsError(try store.loadItem(id: "nope"))
    }

    /// `narrationRendersOnDevice` asked `text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false`.
    func testHasListenableTextIsTheOldWhitespaceTestForNeighbouringTexts() throws {
        let texts: [String?] = [nil, "", " ", "\n\n", " \t\n ", "x", " x ", "\u{00A0}", "\u{2003}word", "Line one.\nLine two."]
        let items = texts.enumerated().map { article("t\($0.offset)", text: $0.element) }
        let store = try openStore(with: items)
        _ = try store.listItemSummaries() // the stored-slice path
        for item in items {
            let old = item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            XCTAssertEqual(try XCTUnwrap(try store.loadItemSummary(id: item.id)).hasListenableText, old, "text \(String(describing: item.text))")
        }
    }

    func testTheSummaryCarriesWhatTheMediaChecksRead() throws {
        var podcast = article("p", text: nil)
        podcast.mediaType = "podcast"
        podcast.media = ItemMedia(sourceType: .remoteStream, url: "https://example.com/a.mp3")
        var book = article("k", text: nil)
        book.mediaType = "audiobook"
        book.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/book.m4b")
        let store = try openStore(with: [podcast, book])

        let podcastSummary = try XCTUnwrap(try store.loadItemSummary(id: "p"))
        XCTAssertEqual(podcastSummary.media?.sourceType, .remoteStream)
        XCTAssertEqual(podcastSummary.media?.url, "https://example.com/a.mp3")
        let bookSummary = try XCTUnwrap(try store.loadItemSummary(id: "k"))
        XCTAssertEqual(bookSummary.mediaType, "audiobook")
        XCTAssertEqual(bookSummary.media?.url, "file:///tmp/book.m4b")
    }
}
