import Foundation
import XCTest
@testable import SessionKit

/// #980: the Preparing Audio screen's rules, moved out of Gate1AppModel so they run on Linux. The
/// ordering itself is LibraryAudioPreparationQueueTests'; these pin what the screen builds on it.
final class AudioPreparationQueueProjectionTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func job(
        _ item: String,
        policy: PreparationJobPolicy = .whileCharging,
        requestedAt seconds: TimeInterval = 0,
        limit: Int? = nil,
        priority: Int? = nil,
        cancelled: Bool = false
    ) -> AudioPreparationJob {
        var job = AudioPreparationJob(
            id: "job-\(item)", itemId: item, manifestId: "manifest-\(item)", policy: policy,
            requestedAt: date(seconds), maximumChunkCount: limit, isCancelled: cancelled
        )
        job.userPriority = priority // the initializer clamps below zero; a prioritized job is stored negative
        return job
    }

    private func manifest(
        _ item: String,
        state: PreparedAudioState = .readyOffline,
        updatedAt seconds: TimeInterval = 0,
        planned: Int = 4,
        committed: Int = 0,
        withArtifact: Bool = true,
        id: String? = nil
    ) -> PreparedAudioManifest {
        let source = SourceLocator(documentId: "doc", spineItemId: nil, segmentId: "seg", utf8Start: 0, utf8End: 10)
        let chunks = (0..<committed).map {
            PreparedAudioChunk(
                id: "chunk-\(item)-\($0)", index: $0, sourceRange: source, relativePath: "c\($0).m4a",
                byteCount: 1, checksumSHA256: "x", durationMs: 1000
            )
        }
        return PreparedAudioManifest(
            id: id ?? "manifest-\(item)", itemId: item, sourcePackageId: "source",
            signature: TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "digest"
            ),
            state: state, plannedChunkCount: planned, chunks: chunks,
            artifact: withArtifact ? PreparedAudioArtifact(relativePath: "a.m4a", byteCount: 1, checksumSHA256: "x", durationMs: 90_000) : nil,
            createdAt: date(0), updatedAt: date(seconds)
        )
    }

    private func rows(_ jobs: [AudioPreparationJob], active: String? = nil, stale: Set<String> = []) -> [AudioPreparationQueueRow] {
        let ordered = AudioPreparationQueueProjection.orderedJobs(jobs, staleJobIds: stale, activeItemId: active)
        return AudioPreparationQueueProjection.queueRows(
            jobs: ordered, manifestsById: [:], titlesByItemId: [:], activeItemId: active)
    }

    // MARK: Queue rows

    func testAJobInTheSameTierCanMoveAndTheEndsCannotMovePastEachOther() {
        let queue = rows([job("a", requestedAt: 3), job("b", requestedAt: 2), job("c", requestedAt: 1)])
        XCTAssertEqual(queue.map(\.itemId), ["a", "b", "c"], "newest first")
        XCTAssertEqual(queue.map(\.canMoveEarlier), [false, true, true])
        XCTAssertEqual(queue.map(\.canMoveLater), [true, true, false])
    }

    func testTheQueueNeverMovesAJobAcrossTiers() {
        // Same policy but one has an opening-buffer limit; another policy entirely.
        let queue = rows([
            job("buffer", policy: .demandWindow, requestedAt: 5, limit: 2),
            job("wanted", policy: .explicit, requestedAt: 4),
            job("charging-a", requestedAt: 3),
            job("charging-b", requestedAt: 2),
        ])
        XCTAssertEqual(queue.map(\.itemId), ["buffer", "wanted", "charging-a", "charging-b"])
        XCTAssertEqual(queue.map(\.canMoveEarlier), [false, false, false, true])
        XCTAssertEqual(queue.map(\.canMoveLater), [false, false, true, false])
    }

    func testTheSameChunkLimitTierMeansHavingALimitNotTheSameLimit() {
        let queue = rows([
            job("a", policy: .demandWindow, requestedAt: 2, limit: 2),
            job("b", policy: .demandWindow, requestedAt: 1, limit: 6),
        ])
        XCTAssertEqual(queue.map(\.canMoveLater), [true, false])
    }

    func testAnOpeningBufferAndAFullDemandJobOfTheSamePolicyAreDifferentTiers() {
        let queue = rows([
            job("buffer", policy: .demandWindow, requestedAt: 2, limit: 2),
            job("full", policy: .demandWindow, requestedAt: 1),
        ])
        XCTAssertEqual(queue.map(\.itemId), ["buffer", "full"], "opening buffers go first")
        XCTAssertEqual(queue.map(\.canMoveEarlier), [false, false])
        XCTAssertEqual(queue.map(\.canMoveLater), [false, false])
    }

    func testThePlayingItemIsPinnedAndNothingMovesAcrossIt() {
        let queue = rows([job("a", requestedAt: 3), job("playing", requestedAt: 1), job("c", requestedAt: 2)], active: "playing")
        XCTAssertEqual(queue.map(\.itemId), ["playing", "a", "c"], "the playing item goes first")
        XCTAssertEqual(queue.first?.isActivePlaybackItem, true)
        XCTAssertEqual(queue.first?.canMoveEarlier, false)
        XCTAssertEqual(queue.first?.canMoveLater, false, "pinned: it can't move even to a neighbour in its tier")
        XCTAssertEqual(queue[1].canMoveEarlier, false, "the job below the playing item can't move up over it")
        XCTAssertEqual(queue[1].canMoveLater, true)
    }

    func testCancelledAndStaleJobsAreNotListed() {
        let queue = rows(
            [job("keep", requestedAt: 3), job("cancelled", requestedAt: 2, cancelled: true), job("stale", requestedAt: 1)],
            stale: ["job-stale"])
        XCTAssertEqual(queue.map(\.itemId), ["keep"])
    }

    func testARowTakesItsNumbersFromTheManifestAndFallsBackToTheJob() throws {
        var limited = job("a", policy: .demandWindow, limit: 2)
        limited.nextChunkIndex = 1
        let withManifest = AudioPreparationQueueProjection.queueRows(
            jobs: [limited], manifestsById: ["manifest-a": manifest("a", state: .preparing, planned: 9, committed: 5).summary],
            titlesByItemId: ["a": "Article A"], activeItemId: nil)
        let row = try XCTUnwrap(withManifest.first)
        XCTAssertEqual(row.title, "Article A")
        XCTAssertEqual(row.state, .preparing)
        XCTAssertEqual(row.completedChunkCount, 2, "capped by the job's chunk limit")
        XCTAssertEqual(row.plannedChunkCount, 2)

        let withoutManifest = try XCTUnwrap(AudioPreparationQueueProjection.queueRows(
            jobs: [limited], manifestsById: [:], titlesByItemId: [:], activeItemId: nil).first)
        XCTAssertEqual(withoutManifest.title, "a", "a missing item shows its id")
        XCTAssertEqual(withoutManifest.state, .failed, "no manifest reads as failed")
        XCTAssertEqual(withoutManifest.completedChunkCount, 1, "the job's own next chunk index")
        XCTAssertEqual(withoutManifest.plannedChunkCount, 2)
    }

    func testARowShowsTheJobsFailureBeforeTheManifestsAndFallsBackToTheRequestTime() throws {
        var failed = job("a", requestedAt: 7)
        failed.lastFailureCode = "job_failure"
        var broken = manifest("a", state: .failed, updatedAt: 40)
        broken.failureCode = "manifest_failure"
        let both = try XCTUnwrap(AudioPreparationQueueProjection.queueRows(
            jobs: [failed], manifestsById: ["manifest-a": broken.summary], titlesByItemId: [:], activeItemId: nil).first)
        XCTAssertEqual(both.failureCode, "job_failure")
        XCTAssertEqual(both.updatedAt, date(40))

        failed.lastFailureCode = nil
        let manifestOnly = try XCTUnwrap(AudioPreparationQueueProjection.queueRows(
            jobs: [failed], manifestsById: ["manifest-a": broken.summary], titlesByItemId: [:], activeItemId: nil).first)
        XCTAssertEqual(manifestOnly.failureCode, "manifest_failure")

        let neither = try XCTUnwrap(AudioPreparationQueueProjection.queueRows(
            jobs: [failed], manifestsById: [:], titlesByItemId: [:], activeItemId: nil).first)
        XCTAssertEqual(neither.updatedAt, date(7), "no manifest: the request time")
        XCTAssertNil(neither.failureCode)
    }

    func testAProgressUpdateDropsCancelledJobsAndShowsTheCurrentJobsFailure() throws {
        var current = job("a", requestedAt: 3)
        current.lastFailureCode = "paused"
        let other = job("b", requestedAt: 2)
        var cancelled = other
        cancelled.isCancelled = true
        let shown = rows([current, other])
        let updated = AudioPreparationQueueProjection.rows(
            shown, afterProgressOn: manifest("a", state: .preparing), currentJob: current,
            remainingJobs: [current, cancelled], activeItemId: nil)
        XCTAssertEqual(updated.map(\.itemId), ["a"], "a cancelled job leaves the queue")
        XCTAssertEqual(updated.first?.failureCode, "paused")
        XCTAssertEqual(updated.first?.title, shown.first?.title)
        XCTAssertEqual(updated.first?.requestedAt, shown.first?.requestedAt)
    }

    func testAProgressUpdateKeepsOnlyRemainingJobsAndUpdatesTheOneBeingPrepared() throws {
        let first = job("a", requestedAt: 3)
        let second = job("b", requestedAt: 2)
        let third = job("c", requestedAt: 1)
        let shown = rows([first, second, third])
        let progressed = manifest("b", state: .preparing, updatedAt: 50, planned: 6, committed: 3)
        let updated = AudioPreparationQueueProjection.rows(
            shown, afterProgressOn: progressed, currentJob: second, remainingJobs: [second, third], activeItemId: nil)
        XCTAssertEqual(updated.map(\.itemId), ["b", "c"], "the finished job drops out")
        let current = try XCTUnwrap(updated.first)
        XCTAssertEqual(current.state, .preparing)
        XCTAssertEqual(current.completedChunkCount, 3)
        XCTAssertEqual(current.plannedChunkCount, 6)
        XCTAssertEqual(current.updatedAt, date(50))
        XCTAssertEqual(current.canMoveEarlier, false)
        XCTAssertEqual(current.canMoveLater, true)
        XCTAssertEqual(updated[1].completedChunkCount, shown[2].completedChunkCount, "other rows keep their numbers")
    }

    func testAProgressUpdateHonoursTheOpeningBufferLimitAndThePinnedItem() throws {
        let playing = job("playing", policy: .demandWindow, requestedAt: 1, limit: 2)
        let other = job("other", policy: .demandWindow, requestedAt: 2, limit: 2)
        let shown = rows([playing, other], active: "playing")
        let updated = AudioPreparationQueueProjection.rows(
            shown, afterProgressOn: manifest("playing", state: .preparing, planned: 8, committed: 5),
            currentJob: playing, remainingJobs: [playing, other], activeItemId: "playing")
        let row = try XCTUnwrap(updated.first)
        XCTAssertEqual(row.itemId, "playing")
        XCTAssertEqual(row.completedChunkCount, 2, "capped by the limit")
        XCTAssertEqual(row.plannedChunkCount, 2)
        XCTAssertTrue(row.isActivePlaybackItem)
        XCTAssertFalse(row.canMoveLater)
        XCTAssertFalse(updated[1].canMoveEarlier, "can't move above the playing item")
    }

    func testTheTwoRowBuildersAgreeOnWhoCanMove() {
        // The refresh and the per-chunk update used to carry their own copies of the tier rule.
        let jobs = [
            job("p", policy: .demandWindow, requestedAt: 9, limit: 2),
            job("a", policy: .demandWindow, requestedAt: 8, limit: 2),
            job("b", policy: .demandWindow, requestedAt: 7),
            job("c", policy: .whileCharging, requestedAt: 6),
            job("d", policy: .whileCharging, requestedAt: 5),
        ]
        for active in [nil, "p", "a", "c"] as [String?] {
            let built = rows(jobs, active: active)
            let current = jobs.first { $0.itemId == built[0].itemId }!
            let updated = AudioPreparationQueueProjection.rows(
                built, afterProgressOn: manifest(current.itemId, state: .preparing), currentJob: current,
                remainingJobs: jobs, activeItemId: active)
            XCTAssertEqual(updated.map(\.canMoveEarlier), built.map(\.canMoveEarlier), "earlier, active \(active ?? "none")")
            XCTAssertEqual(updated.map(\.canMoveLater), built.map(\.canMoveLater), "later, active \(active ?? "none")")
        }
    }

    // MARK: Moving and prioritizing

    func testMovingAJobSwapsItWithItsTierNeighbourAndNumbersTheTier() throws {
        let jobs = [job("a", requestedAt: 3), job("b", requestedAt: 2), job("c", requestedAt: 1), job("other", policy: .explicit, requestedAt: 9)]
        let moved = try XCTUnwrap(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "job-b", by: -1, activeItemId: nil))
        XCTAssertEqual(moved.map(\.itemId), ["b", "a", "c"], "the explicit job is another tier and isn't touched")
        XCTAssertEqual(moved.map(\.userPriority), [0, 1, 2])
    }

    func testMovingStopsAtTheEndsOfTheTierAndForTheActiveItem() {
        let jobs = [job("a", requestedAt: 3), job("b", requestedAt: 2)]
        XCTAssertNil(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "job-a", by: -1, activeItemId: nil))
        XCTAssertNil(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "job-b", by: 1, activeItemId: nil))
        XCTAssertNil(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "job-a", by: 1, activeItemId: "a"), "the playing item is pinned")
        XCTAssertNil(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "missing", by: 1, activeItemId: nil))
    }

    func testMovingLeavesThePlayingItemOutOfTheTier() throws {
        let jobs = [job("a", requestedAt: 3), job("playing", requestedAt: 2), job("c", requestedAt: 1)]
        let moved = try XCTUnwrap(AudioPreparationQueueProjection.reorderedTier(of: jobs, moving: "job-a", by: 1, activeItemId: "playing"))
        XCTAssertEqual(moved.map(\.itemId), ["c", "a"])
    }

    func testPrioritizingPutsOneJobAheadOfEveryRankedJob() {
        XCTAssertEqual(AudioPreparationQueueProjection.nextUserPriority(among: [job("a"), job("b")]), -1, "no ranks yet")
        XCTAssertEqual(AudioPreparationQueueProjection.nextUserPriority(among: [job("a", priority: 2), job("b", priority: -3)]), -4)
        XCTAssertEqual(AudioPreparationQueueProjection.nextUserPriority(among: [job("a", priority: 5)]), 4, "one below the lowest rank, even above zero")
        XCTAssertEqual(AudioPreparationQueueProjection.nextUserPriority(among: []), -1)
        XCTAssertEqual(
            AudioPreparationQueueProjection.nextUserPriority(among: [job("a", priority: Int.min + 1)]), Int.min,
            "stops at the bottom of Int")
    }

    // MARK: Recently prepared

    func testRecentlyPreparedKeepsOneRowPerItemNewestFirst() {
        let list = AudioPreparationQueueProjection.recentlyPrepared(
            manifests: [
                manifest("a", updatedAt: 10, id: "a-old"),
                manifest("b", updatedAt: 30),
                manifest("a", updatedAt: 20, id: "a-new"),
            ].map(\.summary),
            titlesByItemId: ["a": "Alpha", "b": "Beta"])
        XCTAssertEqual(list.map(\.id), ["manifest-b", "a-new"])
        XCTAssertEqual(list.map(\.title), ["Beta", "Alpha"])
        XCTAssertEqual(list.map(\.completedAt), [date(30), date(20)])
        XCTAssertEqual(list.map(\.durationMs), [90_000, 90_000])
    }

    func testRecentlyPreparedListsOnlyFinishedAudioWithAnArtifact() {
        let list = AudioPreparationQueueProjection.recentlyPrepared(
            manifests: [
                manifest("preparing", state: .preparing),
                manifest("no-artifact", withArtifact: false),
                manifest("failed", state: .failed),
                manifest("done"),
            ].map(\.summary),
            titlesByItemId: [:])
        XCTAssertEqual(list.map(\.itemId), ["done"])
        XCTAssertEqual(list.first?.title, "done", "a missing item shows its id")
    }

    func testRecentlyPreparedStopsAtTen() {
        let manifests = (0..<14).map { manifest("item-\($0)", updatedAt: Double($0)).summary }
        let list = AudioPreparationQueueProjection.recentlyPrepared(manifests: manifests, titlesByItemId: [:])
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.first?.itemId, "item-13")
        XCTAssertEqual(list.last?.itemId, "item-4")
    }

    // MARK: The notice

    private func recent(_ title: String, at seconds: TimeInterval) -> RecentlyPreparedAudioRow {
        RecentlyPreparedAudioRow(id: "m-\(title)", itemId: title, title: title, completedAt: date(seconds), durationMs: 1)
    }

    func testTheNoticeNamesOneTitle() {
        let notice = AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: [recent("Alpha", at: 200), recent("Old", at: 50)], lastNoticeTimestamp: 100, now: date(300))
        XCTAssertEqual(notice?.message, "Ready offline: Alpha.")
        XCTAssertEqual(notice?.newestCompletedAt, date(200))
    }

    func testTheNoticeNamesTheNewestAndACount() {
        let notice = AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: [recent("Alpha", at: 300), recent("Beta", at: 200), recent("Gamma", at: 150), recent("Old", at: 50)],
            lastNoticeTimestamp: 100, now: date(400))
        XCTAssertEqual(notice?.message, "Ready offline: Alpha and 2 more. Review them in Preparing Audio.")
        XCTAssertEqual(notice?.newestCompletedAt, date(300))
    }

    func testTheNoticeCountsOneMoreForTwoCompletions() {
        let notice = AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: [recent("Alpha", at: 300), recent("Beta", at: 200)], lastNoticeTimestamp: 100, now: date(400))
        XCTAssertEqual(notice?.message, "Ready offline: Alpha and 1 more. Review them in Preparing Audio.")
    }

    func testTheNoticeIsSilentWhenNothingIsNewerThanTheLastOne() {
        XCTAssertNil(AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: [recent("Alpha", at: 100)], lastNoticeTimestamp: 100, now: date(400)), "equal is not newer")
        XCTAssertNil(AudioPreparationQueueProjection.preparedAudioNotice(recentlyPrepared: [], lastNoticeTimestamp: nil, now: date(400)))
    }

    func testWithoutAStoredDateOnlyTheLastDayIsAnnounced() {
        let now = date(1_000_000)
        let day = AudioPreparationQueueProjection.noticeLookback
        XCTAssertEqual(day, 86_400)
        let notice = AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: [recent("Recent", at: 1_000_000 - day + 1), recent("Stale", at: 1_000_000 - day)],
            lastNoticeTimestamp: nil, now: now)
        XCTAssertEqual(notice?.message, "Ready offline: Recent.", "exactly a day old is not announced")
    }

    // MARK: Keys the app persists

    func testThePersistedKeysAreTheOnesBuild29Wrote() {
        XCTAssertEqual(AudioPreparationQueueProjection.lastNoticeDateDefaultsKey, "lastPreparedAudioNoticeDateV1")
        XCTAssertEqual(AudioPreparationQueueProjection.suppressedItemIdsDefaultsKey, "suppressedAudioPreparationItemIdsV1")
        XCTAssertEqual(AudioPreparationQueueProjection.recentlyPreparedLimit, 10)
    }

    // MARK: The row types

    func testRowProgressIsZeroWithoutAPlanAndNeverAboveOne() {
        func progress(done: Int, planned: Int) -> Double {
            AudioPreparationQueueRow(
                id: "j", itemId: "i", title: "T", policy: .explicit, state: .preparing,
                completedChunkCount: done, plannedChunkCount: planned, requestedAt: date(0), updatedAt: date(0),
                failureCode: nil, isActivePlaybackItem: false, canMoveEarlier: false, canMoveLater: false
            ).progress
        }
        XCTAssertEqual(progress(done: 3, planned: 0), 0)
        XCTAssertEqual(progress(done: 1, planned: 4), 0.25)
        XCTAssertEqual(progress(done: 9, planned: 4), 1)
    }
}
