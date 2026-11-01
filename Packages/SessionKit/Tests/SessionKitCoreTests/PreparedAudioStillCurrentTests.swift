import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// `PreparedAudioEnqueue.isStillCurrent` is the check the Supertonic assembly makes before and after it builds the
/// whole audio. It runs through `StoreReader` now (#2506), so it must answer the same as the main-actor version did.
final class PreparedAudioStillCurrentTests: XCTestCase {
    private let sourceText = "Paper\nWe measured sleep in adults."

    private func makeStore() throws -> (SQLiteSessionStore, Item, PreparedAudioManifest, () -> Void) {
        let path = FileManager.default.temporaryDirectory.appending(path: "still-current-\(UUID()).sqlite")
        let store = try SQLiteSessionStore(path: path.path)
        let engine = SessionEngine(profile: .init(id: "p", displayName: "P", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let item = try engine.importBrowserTextInBackground(.init(
            captureMode: .markdownFile, source: .init(url: "shared-file://share-sheet/Paper.pdf", title: "Paper"),
            text: sourceText, contentFormat: .plainText))
        let manifest = PreparedAudioManifest(
            id: "prepared", itemId: item.id, sourcePackageId: "source",
            signature: .init(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                             synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
            state: .preparing, plannedChunkCount: 1)
        try store.savePreparedAudioManifest(manifest)
        return (store, item, manifest, { try? FileManager.default.removeItem(at: path) })
    }

    func testASavedPreparationOfTheSameTextIsCurrent() throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        XCTAssertTrue(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: item.text, sourceText: item.text!, repository: store))
    }

    func testAnotherSourceTextOrItemTextIsNotCurrent() throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: item.text, sourceText: item.text! + " More.", repository: store))
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: "Different", sourceText: item.text!, repository: store))
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: nil, sourceText: item.text!, repository: store))
    }

    func testAPreparationThatIsNotSavedOrWasRetiredIsNotCurrent() throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        var other = manifest
        other.id = "never-saved"
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(other, itemText: item.text, sourceText: item.text!, repository: store))
        try store.deletePreparedAudioManifest(id: manifest.id)
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: item.text, sourceText: item.text!, repository: store))
    }

    func testAnItemInTheTrashIsNotCurrent() throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        try store.moveItemToTrash(id: item.id)
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(manifest, itemText: item.text, sourceText: item.text!, repository: store))
    }

    func testTheCheckRunsOffTheMainActorThroughTheStoreReader() async throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        let text = item.text
        let current = try await StoreReader(store).read { [manifest, text] in
            PreparedAudioEnqueue.isStillCurrent(manifest, itemText: text, sourceText: text!, repository: $0)
        }
        XCTAssertTrue(current)
    }

    /// A cancelled background pass must see the cancel, not "no longer current": the app keeps the job to retry on a
    /// cancel and drops it on a stale preparation (audit on #3166).
    func testACancelledCheckThrowsInsteadOfAnsweringNotCurrent() async throws {
        let (store, item, manifest, cleanup) = try makeStore()
        defer { cleanup() }
        let text = item.text
        let task = Task {
            try await StoreReader(store).read { [manifest, text] in
                PreparedAudioEnqueue.isStillCurrent(manifest, itemText: text, sourceText: text!, repository: $0)
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled check must throw")
        } catch is CancellationError {}
    }
}
