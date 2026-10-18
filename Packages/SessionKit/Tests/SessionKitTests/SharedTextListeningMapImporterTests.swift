import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest

/// Adding a shared Listening Map to the article or PDF the listener already has (#1471), against a real SQLite store.
final class SharedTextListeningMapImporterTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedTextListeningMapImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("recipient.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let paragraphs = [
        "The harbour town woke slowly that morning, with the fishing boats rocking against their ropes and the gulls arguing over scraps on the quay.",
        "Marta carried her father's ledger down to the customs shed, where a clerk with ink on his cuffs promised to read every line before noon.",
        "By midday the wind had turned, and the captains began to say that the barometer was falling faster than anyone had seen since the great storm.",
        "Nobody believed the old signalman until the lamps along the breakwater began to swing, and then the whole street went quiet at once.",
        "Evening brought the first rain, a thin grey curtain that blurred the lights of the ferry and sent the children running for the arcade."
    ]
    private var text: String { paragraphs.joined(separator: "\n\n") }

    private func package(mapId: String = "map-harbour", summaries: Bool = true) throws -> VerifiedSpokenMarginsPackage {
        let blocks = ListeningEdition.blocks(in: text)
        let scenes = blocks.enumerated().map { index, block in
            ListeningMapPacketBuilder.Scene(
                title: "Part \(index + 1)", summary: summaries ? "Summary \(index + 1) of the harbour story." : "",
                startChar: block.startChar, endChar: block.endChar
            )
        }
        let proposal = try ListeningMapPacketBuilder.proposal(
            id: mapId, generator: "test", languageCode: "en", createdAt: created, scenes: scenes, text: text
        )
        let item = ListeningMapPacketBuilder.identity(itemType: .text, title: "The Harbour Town", canonicalURL: "https://example.com/harbour", text: text)
        let prepared = try ListeningMapPacketBuilder.prepare(
            packageId: "packet-\(mapId)", createdAt: created, item: item, proposal: proposal, senderDisplayLabel: "A Friend"
        )
        let url = root.appendingPathComponent("\(UUID().uuidString).spokenmargins")
        try exportMapOnlyPacket(prepared, to: url)
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets-\(UUID().uuidString)"))
    }

    private func seed(text body: String?, id: String = "item-1") throws -> Item {
        let item = Item(id: id, title: "The Harbour Town", mediaType: "text", text: body,
                        externalReference: "https://example.com/harbour", status: "ready", externalReferenceType: "url")
        try store.seed(item: item)
        return item
    }

    func testAddingAMapSavesChaptersOnTheListenersTextAndKeepsTheSummaries() throws {
        let item = try seed(text: text)
        let outcome = try SharedTextListeningMapImporter.importMap(try package(), into: item, senderLabel: "A Friend", repository: store)
        XCTAssertEqual(outcome, .added(placed: 5, total: 5, replacedAnotherMap: false))
        let map = try XCTUnwrap(store.loadListeningMap(itemId: item.id))
        XCTAssertEqual(map.chapters.map(\.title), (1...5).map { "Part \($0)" })
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertEqual(map.chapters.last?.endChar, text.count)
        XCTAssertEqual(map.overview, "Chapters shared by A Friend.")
        let proposal = try XCTUnwrap(store.loadPortableListeningMapProposals(itemId: item.id).first)
        XCTAssertEqual(proposal.id, "map-harbour")
        XCTAssertEqual(proposal.scenes.map(\.summaryText), (1...5).map { "Summary \($0) of the harbour story." })
        XCTAssertEqual(proposal.scenes.map { $0.startAnchor.startChar }, map.chapters.map { $0.startChar })
    }

    func testAddingTheSameMapTwiceChangesNothing() throws {
        let item = try seed(text: text)
        let contents = try package()
        _ = try SharedTextListeningMapImporter.importMap(contents, into: item, repository: store)
        let before = try store.loadListeningMap(itemId: item.id)
        let outcome = try SharedTextListeningMapImporter.importMap(contents, into: item, repository: store)
        XCTAssertEqual(outcome, .alreadyAdded(chapterCount: 5))
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id), before)
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: item.id).count, 1)
    }

    func testAnotherMapReplacesTheFirstAndTheOutcomeSaysSo() throws {
        let item = try seed(text: text)
        _ = try SharedTextListeningMapImporter.importMap(try package(mapId: "map-a"), into: item, repository: store)
        let contents = try package(mapId: "map-b")
        let proposal = try XCTUnwrap(ListeningMapPacket.proposal(in: contents))
        XCTAssertEqual(try SharedTextListeningMapImporter.existing(for: proposal, itemId: item.id, repository: store), .differentMap)
        let outcome = try SharedTextListeningMapImporter.importMap(contents, into: item, repository: store)
        XCTAssertEqual(outcome, .added(placed: 5, total: 5, replacedAnotherMap: true))
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.chapters.count, 5)
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: item.id).map(\.id), ["map-b"], "only the new map is left to read")
        // Going back to the first map is a replacement again, not "already there".
        let first = try XCTUnwrap(ListeningMapPacket.proposal(in: try package(mapId: "map-a")))
        XCTAssertEqual(try SharedTextListeningMapImporter.existing(for: first, itemId: item.id, repository: store), .differentMap)
    }

    func testAnItemWithNoMapSaysNoneAndAHeadingMapDoesNotCountAsAnotherMap() throws {
        let item = try seed(text: text)
        try store.saveListeningMap(ListeningMap(id: "derived", itemId: item.id, overview: "", chapters: [
            Chapter(id: "h1", title: "Heading", startChar: 0, endChar: 10, percent: 0)
        ]))
        let proposal = try XCTUnwrap(ListeningMapPacket.proposal(in: try package()))
        XCTAssertEqual(try SharedTextListeningMapImporter.existing(for: proposal, itemId: item.id, repository: store), .none)
        let outcome = try SharedTextListeningMapImporter.importMap(try package(), into: item, repository: store)
        XCTAssertEqual(outcome, .added(placed: 5, total: 5, replacedAnotherMap: false))
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.chapters.count, 5, "the sender's chapters replace the heading-derived ones")
    }

    func testATextThatLacksTheChaptersSavesNothingAndSaysWhy() throws {
        let item = try seed(text: "Something entirely different about gardens and the weather in spring.")
        XCTAssertThrowsError(try SharedTextListeningMapImporter.importMap(try package(), into: item, repository: store)) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_map_not_found_in_item"))
        }
        XCTAssertNil(try store.loadListeningMap(itemId: item.id))
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: item.id).count, 0)
    }

    func testAnItemWithoutTextSavesNothing() throws {
        let item = try seed(text: nil)
        XCTAssertThrowsError(try SharedTextListeningMapImporter.importMap(try package(), into: item, repository: store))
        XCTAssertNil(try store.loadListeningMap(itemId: item.id))
    }

    func testAPartlyFoundMapKeepsTheFoundChaptersAndCountsTheRest() throws {
        var edited = paragraphs
        edited[2] = "A completely rewritten paragraph that shares no words with the original at all, only a quiet afternoon."
        let item = try seed(text: edited.joined(separator: "\n\n"))
        let outcome = try SharedTextListeningMapImporter.importMap(try package(), into: item, repository: store)
        XCTAssertEqual(outcome, .added(placed: 4, total: 5, replacedAnotherMap: false))
        XCTAssertEqual(outcome.message, "Added 4 of 5 chapters. The rest weren't found in your copy. Playback has not started.")
        let proposal = try XCTUnwrap(store.loadPortableListeningMapProposals(itemId: item.id).first)
        XCTAssertEqual(proposal.scenes.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(proposal.scenes.map(\.title), ["Part 1", "Part 2", "Part 4", "Part 5"])
    }

    func testTheAttachClosureReplacesTheDirectSave() throws {
        let item = try seed(text: text)
        var attached: ListeningMap?
        _ = try SharedTextListeningMapImporter.importMap(try package(), into: item, repository: store) { attached = $0 }
        XCTAssertEqual(attached?.chapters.count, 5)
        XCTAssertNil(try store.loadListeningMap(itemId: item.id), "the closure decides where the map goes")
    }
}
