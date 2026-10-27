import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: the shared-link voiceover save runs behind `StoreReader`; this is the step it runs, on a real store.
final class PublisherAudioSavingTests: XCTestCase {
    private func makeStoreAndItem() throws -> (SQLiteSessionStore, Item, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "article", displayName: "Article", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://harbourletter.substack.com/p/kettleness", title: "Kettleness"),
            text: "Kettleness is a place. The tide comes in slowly. Nobody minds."
        ))
        return (store, item, directory)
    }

    func testTheRecordIsSavedForAnExistingItem() throws {
        let (store, item, directory) = try makeStoreAndItem()
        defer { try? FileManager.default.removeItem(at: directory) }
        let found = PublisherAudio(itemId: item.id, audioURL: "https://cdn.example.com/a.mp3", detectedFrom: "substack_voiceover")

        let saved = try store.savePublisherAudioIfItemExists(found)

        XCTAssertEqual(saved, found)
        XCTAssertEqual(try store.loadPublisherAudio(itemId: item.id), found)
    }

    func testNothingIsSavedWhenTheItemWasRemovedWhileThePageLoaded() throws {
        let (store, _, directory) = try makeStoreAndItem()
        defer { try? FileManager.default.removeItem(at: directory) }
        let found = PublisherAudio(itemId: "gone", audioURL: "https://cdn.example.com/a.mp3", detectedFrom: "substack_voiceover")

        XCTAssertNil(try store.savePublisherAudioIfItemExists(found))
        XCTAssertNil(try store.loadPublisherAudio(itemId: "gone"), "no orphan record is left for an item that is not there")
    }

    func testTheSameRecordingKeepsItsTextMapAndADifferentOneStartsOver() throws {
        let (store, item, directory) = try makeStoreAndItem()
        defer { try? FileManager.default.removeItem(at: directory) }
        var mapped = PublisherAudio(itemId: item.id, audioURL: "https://cdn.example.com/a.mp3", detectedFrom: "feed_enclosure")
        mapped.textMapStatus = "aligned(3 of 3 sentences)"
        try store.savePublisherAudio(mapped)

        let again = PublisherAudio(itemId: item.id, audioURL: "https://cdn.example.com/a.mp3", detectedFrom: "substack_voiceover")
        XCTAssertEqual(try store.savePublisherAudioIfItemExists(again)?.textMapStatus, "aligned(3 of 3 sentences)")

        let other = PublisherAudio(itemId: item.id, audioURL: "https://cdn.example.com/b.mp3", detectedFrom: "substack_voiceover")
        XCTAssertNil(try store.savePublisherAudioIfItemExists(other)?.textMapStatus)
        XCTAssertEqual(try store.loadPublisherAudio(itemId: item.id)?.audioURL, "https://cdn.example.com/b.mp3")
    }

    /// A save followed by a read through `StoreReader` sees the save, and the main actor is free meanwhile.
    func testTheSaveThroughStoreReaderIsSeenByTheNextRead() async throws {
        let (store, item, directory) = try makeStoreAndItem()
        defer { try? FileManager.default.removeItem(at: directory) }
        let found = PublisherAudio(itemId: item.id, audioURL: "https://cdn.example.com/a.mp3", detectedFrom: "substack_voiceover")
        let reader = StoreReader(store)

        _ = try await reader.read { try $0.savePublisherAudioIfItemExists(found) }
        let loaded = try await reader.read { try $0.loadPublisherAudio(itemId: item.id) }

        XCTAssertEqual(loaded, found)
    }
}
