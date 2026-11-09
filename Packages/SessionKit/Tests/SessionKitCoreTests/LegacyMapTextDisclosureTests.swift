import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// The older map record carries a model's overview and scene titles only for a source marked public (#3588, part of #3449).
/// The record is a real SQLite row, so the flag is proven to survive the store and the export resolver.
final class LegacyMapTextDisclosureTests: XCTestCase {
    private let address = "https://example.com/posts/harbour-lights"
    private let text = "First block of the article.\n\nSecond block, longer than the first.\n\nThird block closes it."
    private var folder: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The three paths that write the record

    func testAListeningEditionMapIsFlaggedAsModelWritten() {
        XCTAssertEqual(edition().listeningMap().modelWrittenText, true)
    }

    func testAPastedMapIsFlaggedAsModelWritten() throws {
        let raw = #"{"schemaVersion":"listening-map.v1","overview":"MODEL OVERVIEW","chapters":[{"id":"c1","title":"MODEL SCENE TITLE","description":"d","startChar":0,"endChar":20}]}"#
        let item = Item(id: "pasted", title: "T", mediaType: "text", text: text, externalReference: address, status: "ready", externalReferenceType: "url")
        XCTAssertEqual(try ManualListeningMapParser.parse(raw, item: item).modelWrittenText, true)
    }

    func testTheDeterministicMapsAreNotFlagged() {
        XCTAssertNil(ListeningMap(id: "m", itemId: "i", overview: "o", chapters: []).modelWrittenText)
    }

    // MARK: The export

    func testAnUnmarkedItemExportsNoModelOverviewOrSceneTitleFromEitherSource() throws {
        for (label, map) in [("edition", edition().listeningMap()), ("pasted", pasted())] {
            let item = try save(item(id: "unmarked-\(label)", marked: false), map: map)
            let exported = try XCTUnwrap(ListeningMapExportResolver.resolve(item: item, repository: store, durationMs: nil), label)
            XCTAssertEqual(exported.overview, "", label)
            XCTAssertEqual(exported.chapters.map(\.title), ["Scene 1", "Scene 2"], label)
            XCTAssertEqual(exported.chapters.map(\.startChar), map.chapters.map(\.startChar), "\(label): the scene starts stay")
            XCTAssertEqual(exported.chapters.map(\.id), map.chapters.map(\.id), label)
            XCTAssertNil(exported.modelWrittenText, "\(label): the storage flag never reaches an export")
            let json = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
            XCTAssertFalse(json.contains("MODEL"), "\(label): \(json)")
            XCTAssertFalse(json.contains("modelWrittenText"), label)
        }
    }

    func testAMarkedPublicItemKeepsEverything() throws {
        for (label, map) in [("edition", edition().listeningMap()), ("pasted", pasted())] {
            let item = try save(item(id: "marked-\(label)", marked: true), map: map)
            let exported = try XCTUnwrap(ListeningMapExportResolver.resolve(item: item, repository: store, durationMs: nil), label)
            XCTAssertEqual(exported.overview, map.overview, label)
            XCTAssertEqual(exported.chapters, map.chapters, label)
            XCTAssertNil(exported.modelWrittenText, label)
        }
    }

    func testADeterministicMapOnAnUnmarkedItemKeepsItsHeadings() throws {
        let map = ListeningMap(id: "map-heads", itemId: "heads", overview: "An article in 2 chapters.", chapters: [
            Chapter(id: "h1", title: "Author heading one", startChar: 0, endChar: 27, percent: 0),
            Chapter(id: "h2", title: "Publisher chapter two", startChar: 29, endChar: 60, percent: 40),
        ])
        let item = try save(item(id: "heads", marked: false), map: map)
        XCTAssertEqual(try ListeningMapExportResolver.resolve(item: item, repository: store, durationMs: nil), map)
    }

    // MARK: Records from before the flag

    func testARecordFromBeforeTheFlagDecodesUnflaggedAndExportsAsItDid() throws {
        let json = #"{"id":"old","itemId":"old-item","overview":"Older overview","chapters":[{"id":"c","title":"Older title","startChar":0,"endChar":5,"percent":0}]}"#
        let old = try JSONDecoder().decode(ListeningMap.self, from: Data(json.utf8))
        XCTAssertNil(old.modelWrittenText)
        let item = try save(item(id: "old-item", marked: false), map: old)
        let exported = try XCTUnwrap(ListeningMapExportResolver.resolve(item: item, repository: store, durationMs: nil))
        XCTAssertEqual(exported.overview, "Older overview")
        XCTAssertEqual(exported.chapters.first?.title, "Older title")
    }

    func testAnUnflaggedRecordEncodesWithoutTheKeySoAnOlderBuildSeesTheSameJSON() throws {
        let json = String(decoding: try JSONEncoder().encode(ListeningMap(id: "m", itemId: "i", overview: "o", chapters: [])), as: UTF8.self)
        XCTAssertFalse(json.contains("modelWrittenText"), json)
    }

    func testAFlaggedRecordSurvivesTheStoreAndAnOlderDecoderIgnoresTheKey() throws {
        let item = try save(item(id: "round-trip", marked: false), map: edition().listeningMap())
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.modelWrittenText, true)
        // What Builds 32 and 34 do: decode the same JSON into a record that has no such key.
        struct OlderListeningMap: Decodable { var id: String; var itemId: String; var overview: String; var chapters: [Chapter] }
        let encoded = try JSONEncoder().encode(edition().listeningMap())
        XCTAssertEqual(try JSONDecoder().decode(OlderListeningMap.self, from: encoded).overview, "MODEL OVERVIEW of the article")
    }

    // MARK: Helpers

    private func edition() -> ListeningEdition {
        ListeningEdition(title: "Harbour Lights", sourceURL: address, text: text, generator: "a model", overview: "MODEL OVERVIEW of the article", scenes: [
            .init(title: "MODEL SCENE TITLE", description: "d", summary: "s", startBlock: 1, endBlock: 2),
            .init(title: "ANOTHER MODEL TITLE", description: "d", summary: "s", startBlock: 3, endBlock: 3),
        ])
    }

    private func pasted() -> ListeningMap {
        ListeningMap(id: "map-pasted-manual", itemId: "pasted", overview: "MODEL OVERVIEW of the article", chapters: [
            Chapter(id: "c1", title: "MODEL SCENE TITLE", startChar: 0, endChar: 27, percent: 0),
            Chapter(id: "c2", title: "ANOTHER MODEL TITLE", startChar: 29, endChar: 70, percent: 40),
        ], modelWrittenText: true)
    }

    private func item(id: String, marked: Bool) -> Item {
        var item = Item(id: id, title: "Harbour Lights", mediaType: "text", text: text, externalReference: address, status: "ready", externalReferenceType: "url")
        if marked { item.publicSourceMark = PublicSourceMark(url: address, checkedAt: Date()) }
        return item
    }

    private func save(_ item: Item, map: ListeningMap) throws -> Item {
        try store.saveItem(item)
        var map = map
        map.itemId = item.id
        try store.saveListeningMap(map)
        return item
    }
}
