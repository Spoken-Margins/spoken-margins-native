import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2102: every tap that rebuilt the Library read every item with its whole text, about 100 ms for the owner's 310
/// items. The Library list now reads a summary that never copies or decodes `text` or `documentStructure`.
/// Real SQLite on a real file; the rows built from summaries must equal the rows built from whole items.
final class LibraryItemSummaryReadTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "summary-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ id: String, text: String?, media: ItemMedia? = nil, mediaType: String = "text") -> Item {
        var item = Item(id: id, title: "Title \(id)", mediaType: mediaType, text: text, externalReference: "https://example.com/\(id)",
                        status: "ready", externalReferenceType: "article", media: media, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        // Most carry a feed date so the Published sort has something to read; "nil" and "empty" have none (#1867).
        if id != "nil", id != "empty" { item.publishedAt = "2026-09-29T10:00:00Z" }
        return item
    }

    private let context = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true)

    /// Neighbouring texts: none, empty, spaces, a no-break space, spaces and then words past the look-ahead, accents,
    /// emoji, a long article.
    private func table() -> [Item] {
        let longGap = String(repeating: " ", count: 600) + "words after a long gap"
        var trashed = item("trashed", text: "gone")
        trashed.deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var finished = item("finished", text: "heard already")
        finished.sourceCompletedAt = Date(timeIntervalSince1970: 1_700_000_200)
        return [
            item("plain", text: "Some words to read aloud."),
            item("nil", text: nil),
            item("empty", text: ""),
            item("spaces", text: "   \n\t  "),
            item("nbsp", text: "\u{00A0}\u{00A0}"),
            item("long-gap", text: longGap),
            item("long-blank", text: String(repeating: " ", count: 700)),
            item("accents", text: "caf\u{00E9} na\u{00EF}ve"),
            item("long", text: String(repeating: "A sentence of reasonable length. ", count: 3_000)),
            item("podcast", text: "show notes", media: ItemMedia(sourceType: .nativeMediaFile, url: "a.mp3")),
            trashed, finished,
        ]
    }

    func testSummaryRowsEqualTheRowsOfTheWholeItems() throws {
        let store = try SQLiteSessionStore(path: path)
        let items = table()
        for item in items { try store.saveItem(item) }
        let summaries = try store.listItemSummaries(includeDeleted: true)
        let whole = try store.listItems(includeDeleted: true)
        XCTAssertEqual(summaries.map(\.id), whole.map(\.id), "same order")
        let fromSummaries = LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: summaries, sessions: [], manifests: [], jobs: [], downloads: []), context: context)
        let fromItems = LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: whole, sessions: [], manifests: [], jobs: [], downloads: []), context: context)
        XCTAssertEqual(fromSummaries, fromItems)
        XCTAssertEqual(Set(fromSummaries.map(\.id)), Set(items.map(\.id)).subtracting(["trashed"]))
        for (summary, full) in zip(summaries, whole) {
            XCTAssertEqual(summary.hasListenableText, full.hasListenableText, full.id)
            XCTAssertEqual(summary.textCharacterCount, full.text?.unicodeScalars.count, full.id)
        }
        XCTAssertEqual(summaries.first { $0.id == "long-gap" }?.hasListenableText, true, "words after a long gap still count")
        XCTAssertEqual(summaries.first { $0.id == "long-blank" }?.hasListenableText, false)
        XCTAssertEqual(summaries.first { $0.id == "nbsp" }?.hasListenableText, false)
        // The Published sort reads the feed date off the summary, so it must survive the cut (#1867).
        let expected = ItemMetadata.publishedDate("2026-09-29T10:00:00Z")
        XCTAssertNotNil(expected)
        XCTAssertEqual(fromSummaries.first { $0.id == "plain" }?.publishedAt, expected)
        XCTAssertNil(fromSummaries.first { $0.id == "nil" }?.publishedAt)
    }

    /// #2508: `retryVoiceoverLookupIfNeeded` and `canGenerateListeningMap` ask the store for one item's summary where they
    /// loaded the whole item. They ask "is there any text" and "what is its media", and the answers must not change.
    func testOneItemsSummaryAnswersWhatTheWholeItemAnswered() throws {
        let store = try SQLiteSessionStore(path: path)
        let items = table()
        for item in items { try store.saveItem(item) }
        for item in items {
            let full = try store.loadItem(id: item.id)
            let summary = try XCTUnwrap(try store.loadItemSummary(id: item.id), item.id)
            XCTAssertEqual((summary.textCharacterCount ?? 0) > 0, full.text?.isEmpty == false, "any text at all: \(item.id)")
            XCTAssertEqual(summary.media, full.media, item.id)
            XCTAssertEqual(summary.externalReference, full.externalReference, item.id)
            XCTAssertEqual(summary.title, full.title, item.id)
        }
        XCTAssertNil(try store.loadItemSummary(id: "missing"))
    }

    func testTheSummaryReadDoesNotCarryTheTextOrTheDocumentStructure() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(item("a", text: "Body"))
        let summary = try XCTUnwrap(store.listItemSummaries().first)
        let encoded = try JSONEncoder().encode(summary.title)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Body"))
        XCTAssertEqual(Mirror(reflecting: summary).children.compactMap(\.label).filter { $0 == "text" || $0 == "documentStructure" }, [])
        XCTAssertEqual(try store.loadItem(id: "a").text, "Body", "the item itself is untouched")
    }

    func testTrashedItemsAreLeftOutUnlessAsked() throws {
        let store = try SQLiteSessionStore(path: path)
        for item in table() { try store.saveItem(item) }
        XCTAssertFalse(try store.listItemSummaries().contains { $0.id == "trashed" })
        XCTAssertTrue(try store.listItemSummaries(includeDeleted: true).contains { $0.id == "trashed" })
    }

    func testAnItemThatCannotBeCutOrDecodedIsSetAsideAndTheRestStillRead() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(item("good", text: "Fine."))
        try StoreRawSQL.execute(
            "INSERT INTO records(kind,id,session_id,item_id,payload) VALUES('item','broken',NULL,'broken',?);",
            bindings: [#"{"id":"broken","title":"Broken","mediaType":"text","status":"ready","createdAt":"not a date"}"#], at: path)
        let summaries = try store.listItemSummaries()
        XCTAssertEqual(summaries.map(\.id), ["good"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1, "set aside as the full read would")
    }

    /// The owner's Library: 310 items. The summary must stay fast, and well under the whole read of the same Library.
    /// On the Mac the summary takes about a third of the whole read; on the Linux runner, where `json_remove` costs
    /// more, it took 58%. A summary that still decoded the text would take as long as the whole read, so 80% catches it.
    func testTheSummaryReadOfAThreeHundredItemLibraryIsFastAndMuchFasterThanTheWholeRead() throws {
        let store = try SQLiteSessionStore(path: path)
        let body = String(repeating: "A sentence of reasonable length. ", count: 1_200)
        let huge = String(repeating: "A sentence of reasonable length. ", count: 32_000)
        for index in 0..<300 { try store.saveItem(item("article-\(index)", text: body)) }
        for index in 0..<10 { try store.saveItem(item("book-\(index)", text: huge)) }
        _ = try store.listItemSummaries()
        var summaryBest = Double.infinity
        var wholeBest = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            XCTAssertEqual(try store.listItemSummaries().count, 310)
            summaryBest = min(summaryBest, Date().timeIntervalSince(start))
            let wholeStart = Date()
            XCTAssertEqual(try store.listItems().count, 310)
            wholeBest = min(wholeBest, Date().timeIntervalSince(wholeStart))
        }
        XCTAssertLessThan(summaryBest, wholeBest * 0.8, "summary \(summaryBest) s against whole \(wholeBest) s")
    }
}
