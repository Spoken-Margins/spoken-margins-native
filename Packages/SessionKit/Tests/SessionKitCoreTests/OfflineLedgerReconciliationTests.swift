import XCTest
@testable import SessionKit

/// #259: the ledger charged about 1.15 GB of deleted files on the owner's phone.
final class OfflineLedgerReconciliationTests: XCTestCase {
    private func asset(
        _ id: String, _ path: String, _ bytes: Int64,
        category: OfflineAssetCategory = .preparedChunk,
        itemId: String? = nil,
        reproducible: Bool = true,
        protections: Set<OfflineProtectionReason> = []
    ) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: id, itemId: itemId, category: category, relativePath: path, byteCount: bytes,
            isReproducible: reproducible, protections: protections,
            lastAccessedAt: Date(timeIntervalSinceReferenceDate: 100), createdAt: Date(timeIntervalSinceReferenceDate: 50)
        )
    }

    func testRowsForMissingFilesAreDroppedAndSizesComeFromDisk() {
        let assets = [
            asset("adopted-gone", "RenderedSpeechCache/old.wav", 6),
            asset("adopted-shorter", "RenderedSpeechCache/kept.wav", 6),
            asset("unchanged", "PodcastAudio/episode.m4a", 4, category: .podcast)
        ]
        let disk: [String: OfflineLedgerReconciliation.PathState] = [
            "RenderedSpeechCache/kept.wav": .file(byteCount: 2),
            "PodcastAudio/episode.m4a": .file(byteCount: 4)
        ]
        let plan = OfflineLedgerReconciliation.plan(assets: assets) { disk[$0] ?? .missing }

        XCTAssertEqual(plan.removedAssetIds, ["adopted-gone"])
        XCTAssertEqual(plan.updatedAssets.map(\.id), ["adopted-shorter"])
        XCTAssertEqual(plan.updatedAssets.first?.byteCount, 2)
        XCTAssertEqual(plan.bytesNoLongerCharged, 10)
        XCTAssertEqual(plan.summary, "missing=1 resized=1 merged=0 bytes=10")
    }

    func testRowsNamingOneFileBecomeOneKeepingTheWritersIdAndEveryProtection() {
        let assets = [
            asset("adopted-abc", "PreparedAudio/item/chunks/0.wav", 4),
            asset("prepared-item-chunk-0", "PreparedAudio/item/chunks/0.wav", 4, itemId: "item",
                  protections: [.activeEpisodeMapPreparation]),
            asset("adopted-guided", "GuidedOnboarding/tour.m4a", 9, category: .guidedTour, reproducible: false,
                  protections: [.dormantWatchTransfer]),
            asset("guided-onboarding-audio", "GuidedOnboarding/tour.m4a", 9, category: .guidedTour)
        ]
        let plan = OfflineLedgerReconciliation.plan(assets: assets) { path in .file(byteCount: path.hasPrefix("Guided") ? 9 : 4) }

        XCTAssertEqual(plan.removedAssetIds, ["adopted-abc", "adopted-guided"])
        XCTAssertEqual(plan.mergedRowCount, 2)
        XCTAssertEqual(plan.bytesNoLongerCharged, 13, "each file is charged once")
        let guided = plan.updatedAssets.first { $0.id == "guided-onboarding-audio" }
        XCTAssertEqual(guided?.protections, [.dormantWatchTransfer], "a protection on any alias survives the merge")
        XCTAssertEqual(guided?.isReproducible, false, "not reproducible if any alias said so")
    }

    func testDirectoriesAndConsistentRowsAreLeftAlone() {
        let assets = [
            asset("episode-map", "EpisodeMaps/item", 100, category: .fingerprintMap),
            asset("episode", "PodcastAudio/episode.m4a", 4, category: .podcast)
        ]
        let plan = OfflineLedgerReconciliation.plan(assets: assets) {
            $0 == "EpisodeMaps/item" ? .other : .file(byteCount: 4)
        }
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.bytesNoLongerCharged, 0)
    }

    func testAMissingProtectedRowIsDroppedBecauseItChargesForNothing() {
        let plan = OfflineLedgerReconciliation.plan(assets: [
            asset("margin-audio", "Interjections/margin.m4a", 10, category: .interjection, reproducible: false,
                  protections: [.interjection])
        ]) { _ in .missing }
        XCTAssertEqual(plan.removedAssetIds, ["margin-audio"])
    }
}
