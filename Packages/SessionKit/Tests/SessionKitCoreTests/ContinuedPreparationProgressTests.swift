import XCTest
@testable import SessionKit

final class ContinuedPreparationProgressTests: XCTestCase {
    private func job(_ state: PreparedAudioState, done: Int, total: Int = 100) -> OfflinePreparationRun.Job {
        .init(id: "job", manifestId: "manifest", policy: .explicit, state: state,
              completedChunks: done, plannedChunks: total)
    }

    func testACompletedArticleStaysInTheRunProgressWhileTheNextArticleRenders() {
        let jobs = [job(.readyOffline, done: 100), job(.preparing, done: 40)]
        XCTAssertEqual(OfflinePreparationRun.continuedProgress(jobs), .init(completedChunks: 140, totalChunks: 200))
        XCTAssertFalse(OfflinePreparationRun.continuedRunFinished(jobs))
        XCTAssertTrue(OfflinePreparationRun.continuedRunFinished([job(.readyOffline, done: 100)]))
    }

    func testCommittingEveryChunkDoesNotClaimSuccessBeforeAssemblyAndVerification() {
        let rendering = [job(.preparing, done: 100)]
        XCTAssertFalse(OfflinePreparationRun.continuedRunFinished(rendering))
        XCTAssertEqual(OfflinePreparationRun.continuedProgress(rendering).remainingChunks, 1)
        XCTAssertEqual(OfflinePreparationRun.continuedProgress([job(.readyOffline, done: 100)]).remainingChunks, 0)
    }

    func testEmptyFailedStoppedAndInvalidatedRunsNeverClaimSuccess() {
        XCTAssertFalse(OfflinePreparationRun.continuedRunFinished([]))
        for state in [PreparedAudioState.failed, .stopped, .needsRepreparation, .pausedForThermal, .notPrepared] {
            let jobs = [job(state, done: 100)]
            XCTAssertFalse(OfflinePreparationRun.continuedRunFinished(jobs), "\(state)")
            XCTAssertGreaterThan(OfflinePreparationRun.continuedProgress(jobs).remainingChunks, 0)
        }
    }

    func testHeatPausesKeepTheCommittedProgressAndUnrelatedAutomaticWorkIsExcluded() {
        let paused = job(.pausedForThermal, done: 42)
        let automatic = OfflinePreparationRun.Job(policy: .whileCharging, state: .preparing,
                                                  completedChunks: 10, plannedChunks: 200)
        XCTAssertEqual(OfflinePreparationRun.continuedProgress([paused, automatic]), .init(completedChunks: 42, totalChunks: 100))
        XCTAssertEqual(OfflinePreparationRun.openExplicitRequests([paused, automatic]).count, 1)
    }

    func testRemovingAQueueJobRequiresAVerifiedArtifactToCountAsCompletion() {
        let signature = TTSRenderSignature(engine: "test", modelRevision: "1", assetManifestHash: "a",
                                          voiceStyleHash: "v", synthesisParametersHash: "p",
                                          normalizationVersion: "1", chunkingVersion: "1", digest: "d")
        var manifest = PreparedAudioManifest(id: "manifest", itemId: "article", sourcePackageId: "article",
                                             signature: signature, state: .readyOffline, plannedChunkCount: 100)
        let prior = job(.preparing, done: 100)
        XCTAssertEqual(OfflinePreparationRun.resolvingRemovedJob(prior, manifest: nil).state, .stopped)
        XCTAssertEqual(OfflinePreparationRun.resolvingRemovedJob(prior, manifest: manifest).state, .stopped)
        manifest.artifact = PreparedAudioArtifact(relativePath: "verified.m4a", byteCount: 10,
                                                  checksumSHA256: "checksum", durationMs: 1000)
        XCTAssertEqual(OfflinePreparationRun.resolvingRemovedJob(prior, manifest: manifest).state, .readyOffline)
        manifest.state = .failed
        XCTAssertEqual(OfflinePreparationRun.resolvingRemovedJob(prior, manifest: manifest).state, .stopped)
    }
}
