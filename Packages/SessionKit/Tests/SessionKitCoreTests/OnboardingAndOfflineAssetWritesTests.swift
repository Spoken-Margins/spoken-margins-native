import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The guided-tour refresh and the prepared-audio redundancy marks leave the main actor (#2509). Each one applies in a
/// store transaction and keeps what the store holds now.
final class OnboardingAndOfflineAssetWritesTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-writes-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func bundled() -> Item {
        Item(id: "guided-tour", title: "Bundled", mediaType: "guided_tour", text: "Welcome.", externalReference: "bundled://tour",
             status: "ready", externalReferenceType: "guided_onboarding", sourceTitle: "Spoken Margins")
    }

    private func asset(url: String) -> AudioAsset {
        AudioAsset(id: "guided-onboarding-audio", itemId: "guided-tour", audioSourceType: .nativeMediaFile,
                   availability: .localPhone, url: url, title: "Tour")
    }

    private func timeline() -> SourceTranscriptTimeline {
        SourceTranscriptTimeline(id: "timeline-guided-onboarding", itemId: "guided-tour", createdAt: Date(timeIntervalSince1970: 5),
                                 timeline: TranscriptTimeline(segments: [], chapters: []))
    }

    func testTourRefreshSavesItemAssetAndTimelineTogether() throws {
        let store = try makeStore()
        let saved = try OnboardingAndOfflineAssetWrites.applyGuidedTour(
            itemId: "guided-tour", fallback: bundled(),
            edit: { $0.title = "Fresh tour"; $0.media = ItemMedia(sourceType: .nativeMediaFile, url: "https://x/tour.m4a", nativeMediaId: "guided-onboarding-audio") },
            asset: asset(url: "https://x/tour.m4a"), timeline: timeline(), in: store)

        XCTAssertEqual(saved.title, "Fresh tour")
        XCTAssertEqual(try store.loadItem(id: "guided-tour").media?.url, "https://x/tour.m4a")
        XCTAssertEqual(try store.loadAudioAssets(itemId: "guided-tour").map(\.url), ["https://x/tour.m4a"])
        XCTAssertNotNil(try store.loadTranscriptTimeline(id: "timeline-guided-onboarding"))
    }

    /// The tour the listener already has is edited, not replaced by the bundled copy.
    func testTourRefreshEditsTheSavedItemWhenThereIsOne() throws {
        let store = try makeStore()
        var existing = bundled()
        existing.text = "Text from an earlier download."
        try store.saveItem(existing)
        _ = try OnboardingAndOfflineAssetWrites.applyGuidedTour(
            itemId: "guided-tour", fallback: bundled(), edit: { $0.title = "Fresh tour" },
            asset: asset(url: "u"), timeline: timeline(), in: store)
        let item = try store.loadItem(id: "guided-tour")
        XCTAssertEqual(item.text, "Text from an earlier download.")
        XCTAssertEqual(item.title, "Fresh tour")
    }

    func testMarkRedundantChangesOnlyTheItemsAssetsOfThatCategory() throws {
        let store = try makeStore()
        func owned(_ id: String, item: String, _ category: OfflineAssetCategory) -> OwnedOfflineAsset {
            OwnedOfflineAsset(id: id, itemId: item, category: category, relativePath: "\(id).caf", byteCount: 10, isReproducible: true)
        }
        try store.saveOwnedOfflineAsset(owned("chunk-1", item: "a", .preparedChunk))
        try store.saveOwnedOfflineAsset(owned("chunk-2", item: "a", .preparedChunk))
        try store.saveOwnedOfflineAsset(owned("whole", item: "a", .preparedAudio))
        try store.saveOwnedOfflineAsset(owned("other-chunk", item: "b", .preparedChunk))

        XCTAssertEqual(try OnboardingAndOfflineAssetWrites.markRedundant(category: .preparedChunk, itemId: "a", in: store), 2)
        XCTAssertEqual(try OnboardingAndOfflineAssetWrites.markRedundant(category: .preparedChunk, itemId: "a", in: store), 0,
                       "a second run writes nothing")

        let all = Dictionary(uniqueKeysWithValues: try store.loadOwnedOfflineAssets().map { ($0.id, $0.isRedundant) })
        XCTAssertEqual(all, ["chunk-1": true, "chunk-2": true, "whole": false, "other-chunk": false])
    }
}
