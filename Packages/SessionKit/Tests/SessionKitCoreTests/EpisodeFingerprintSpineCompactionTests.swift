import XCTest
@testable import SessionKit

/// #2626: Build 35 left spines holding one post-seek landmark per audio buffer after a seek.
final class EpisodeFingerprintSpineCompactionTests: XCTestCase {
    private func landmark(
        _ start: Int,
        trigger: EpisodeFingerprintTrigger = .stablePostSeek,
        epoch: Int = 1
    ) -> EpisodeFingerprintLandmark {
        EpisodeFingerprintLandmark(
            id: "landmark-\(trigger.rawValue)-\(epoch)-\(start)",
            order: 0,
            sourceMediaStartMs: start,
            sourceMediaEndMs: start + 11_000,
            anchorMediaTimeMs: start,
            continuityEpoch: epoch,
            trigger: trigger,
            provenance: .observedDecodedPlayback,
            signatureAssetId: "sig-\(trigger.rawValue)-\(epoch)-\(start)"
        )
    }

    func testARunawayEpochShrinksToOneLandmarkPerMinute() {
        let runaway = (0..<4_000).map { landmark(100_000 + $0 * 500) }
        let result = EpisodeFingerprintSpineCompaction.compact(existing: runaway)
        // 2,000 s of landmarks, one kept per 60 s window, the earliest first.
        XCTAssertLessThanOrEqual(result.kept.count, 2_000 / 60 + 1)
        XCTAssertEqual(result.kept.first?.sourceMediaStartMs, 100_000)
        XCTAssertEqual(result.kept.count + result.dropped.count, runaway.count)
        XCTAssertEqual(result.kept.map(\.order), Array(0..<result.kept.count))
    }

    func testPeriodicLandmarksAreNeverDropped() {
        let grid = (0..<30).map { landmark(60_000 + $0 * 300_000, trigger: .periodicPlayback, epoch: 0) }
        let result = EpisodeFingerprintSpineCompaction.compact(existing: grid)
        XCTAssertEqual(result.kept.count, 30)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testTheSameEpochNumberInAnotherPlaceInTheEpisodeIsKept() {
        // Epoch numbers restart in every listening session.
        let existing = [landmark(100_000, epoch: 1), landmark(2_000_000, epoch: 1)]
        let result = EpisodeFingerprintSpineCompaction.compact(existing: existing)
        XCTAssertEqual(result.kept.count, 2)
    }

    func testANewLandmarkInAnAlreadyServedEpochIsRefusedAndTheStoredOneStays() {
        let stored = landmark(100_000)
        let result = EpisodeFingerprintSpineCompaction.compact(existing: [stored], adding: landmark(100_500))
        XCTAssertEqual(result.kept.map(\.signatureAssetId), [stored.signatureAssetId])
        XCTAssertFalse(result.keeps(signatureAssetId: landmark(100_500).signatureAssetId))
        XCTAssertEqual(result.dropped.map(\.sourceMediaStartMs), [100_500])
    }

    func testANewLandmarkInANewEpochIsAddedInEpisodeOrder() {
        let periodic = landmark(60_000, trigger: .periodicPlayback, epoch: 0)
        let added = landmark(30_000, epoch: 2)
        let result = EpisodeFingerprintSpineCompaction.compact(existing: [periodic], adding: added)
        XCTAssertEqual(result.kept.map(\.sourceMediaStartMs), [30_000, 60_000])
        XCTAssertEqual(result.kept.map(\.order), [0, 1])
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testRecapturingTheSameSignatureReplacesTheStoredLandmark() {
        let stored = landmark(60_000, trigger: .periodicPlayback, epoch: 0)
        let result = EpisodeFingerprintSpineCompaction.compact(existing: [stored], adding: stored)
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertTrue(result.dropped.isEmpty)
    }
}
