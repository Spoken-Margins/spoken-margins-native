import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The store half of attaching a map runs off the main thread, the engine half on it (#2509).
final class ListeningMapPersisterTests: XCTestCase {
    private func makeStore() throws -> (SQLiteSessionStore, URL) {
        let path = FileManager.default.temporaryDirectory.appending(path: "persister-\(UUID()).sqlite")
        return (try SQLiteSessionStore(path: path.path), path)
    }
    private func engine(_ store: SQLiteSessionStore, capable: Bool = true) -> SessionEngine {
        .init(profile: .init(id: "p", displayName: "P", capabilities: capable ? ["sync": ["canonical_persistence"]] : [:]), repository: store)
    }
    private func markdown() throws -> (Item, ListeningMap) {
        var md = "# T\n\n"
        for n in 1...4 { md += "## Section \(n)\n\n" + String(repeating: "Body of the section. ", count: 20) + "\n\n" }
        let parsed = try ObsidianMarkdownParser.parse(fileName: "t.md", contents: md, titleOverride: "T")
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1", policy: .authoredSections))
        let item = Item(id: "item-1", title: "T", mediaType: "text", text: parsed.text, externalReference: "manual-import",
                        status: "needs_listening_map", externalReferenceType: "manual")
        return (item, map)
    }

    func testPersistWritesMapAndReadyStatusAndLeavesTheEngineAlone() throws {
        let (store, path) = try makeStore(); defer { try? FileManager.default.removeItem(at: path) }
        let (item, map) = try markdown()
        try store.seed(item: item)
        let engine = engine(store)
        let before = engine.snapshot
        let persisted = try engine.listeningMapPersister().persist(map)
        XCTAssertEqual(persisted.item.status, "ready")
        XCTAssertEqual(try store.loadItem(id: item.id).status, "ready")
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.id, map.id)
        XCTAssertEqual(engine.snapshot.itemId, before.itemId, "the store half must not change what the engine shows")
        XCTAssertNil(engine.currentMap)
    }

    func testAdoptLeavesTheEngineAloneWhenItIsOnAnotherItem() throws {
        let (store, path) = try makeStore(); defer { try? FileManager.default.removeItem(at: path) }
        let (item, map) = try markdown()
        var other = item
        other.id = "item-2"
        try store.seed(item: item)
        try store.seed(item: other)
        let engine = engine(store)
        try engine.prepareSpeechText(itemId: other.id, targetType: .itemTextTTS)
        let persisted = try engine.listeningMapPersister().persist(map)
        let before = engine.snapshot
        let snapshot = try engine.attachListeningMap(persisted)
        XCTAssertEqual(snapshot.itemId, before.itemId, "the snapshot is not rewritten for an item that is not open")
        XCTAssertEqual(snapshot.title, before.title)
        XCTAssertEqual(engine.currentItem?.id, other.id)
        XCTAssertNil(engine.currentMap)
    }

    func testAdoptTakesTheMapWhenTheItemIsOpen() throws {
        let (store, path) = try makeStore(); defer { try? FileManager.default.removeItem(at: path) }
        let (item, map) = try markdown()
        try store.seed(item: item)
        let engine = engine(store)
        try engine.prepareSpeechText(itemId: item.id, targetType: .itemTextTTS)
        let persisted = try engine.listeningMapPersister().persist(map)
        XCTAssertNil(engine.currentMap, "persisting alone adopts nothing")
        let snapshot = try engine.attachListeningMap(persisted)
        XCTAssertEqual(engine.currentMap?.id, map.id)
        XCTAssertEqual(engine.currentItem?.status, "ready")
        XCTAssertEqual(snapshot.itemId, item.id)
    }

    func testAttachStillDoesBothHalvesAndRefusesWithoutTheCapability() throws {
        let (store, path) = try makeStore(); defer { try? FileManager.default.removeItem(at: path) }
        let (item, map) = try markdown()
        try store.seed(item: item)
        XCTAssertThrowsError(try engine(store, capable: false).listeningMapPersister())
        XCTAssertThrowsError(try engine(store, capable: false).attachListeningMap(map))
        XCTAssertEqual(try store.loadItem(id: item.id).status, "needs_listening_map", "no capability, no write")
        _ = try engine(store).attachListeningMap(map)
        XCTAssertEqual(try store.loadItem(id: item.id).status, "ready")
    }
}
