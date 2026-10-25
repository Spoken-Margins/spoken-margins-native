import XCTest
@testable import SessionKit

final class OfflinePreparationRecoveryTests: XCTestCase {
    private func job(_ policy: PreparationJobPolicy, cancelled: Bool = false) -> AudioPreparationJob {
        AudioPreparationJob(id: policy.rawValue, itemId: "article", manifestId: "manifest",
                            policy: policy, isCancelled: cancelled)
    }

    func testBackgroundSelectionIncludesExplicitRequestsWithAutomaticPreparationOff() {
        let explicit = job(.explicit)
        let selected = OfflinePreparationRecovery.backgroundJobs(
            [job(.whileCharging), job(.demandWindow), explicit, job(.explicit, cancelled: true)],
            automaticPolicy: .off
        )
        XCTAssertEqual(selected.map(\.id), [explicit.id],
                       "expiry must not strand a listener request when automatic preparation is off")
    }

    func testAutomaticWorkStillRequiresOptInAndCancelledJobsNeverResume() {
        let jobs = [job(.explicit), job(.whileCharging), job(.demandWindow), job(.whileCharging, cancelled: true)]
        XCTAssertEqual(OfflinePreparationRecovery.backgroundJobs(jobs, automaticPolicy: .whileCharging).count, 3)
        XCTAssertTrue(OfflinePreparationRecovery.backgroundJobs([job(.whileCharging)], automaticPolicy: .off).isEmpty)
    }

    func testExplicitRequestsScheduleRecoveryEvenWithBothAutomaticPoliciesOff() {
        XCTAssertTrue(OfflinePreparationRecovery.shouldSchedule(
            jobs: [job(.explicit)], automaticAudio: .off, automaticEpisodeMaps: .off))
        for jobs in [[], [job(.explicit, cancelled: true)], [job(.demandWindow)], [job(.whileCharging)]] {
            XCTAssertFalse(OfflinePreparationRecovery.shouldSchedule(
                jobs: jobs, automaticAudio: .off, automaticEpisodeMaps: .off))
        }
        XCTAssertTrue(OfflinePreparationRecovery.shouldSchedule(
            jobs: [], automaticAudio: .whileCharging, automaticEpisodeMaps: .off))
        XCTAssertTrue(OfflinePreparationRecovery.shouldSchedule(
            jobs: [], automaticAudio: .off, automaticEpisodeMaps: .whileCharging))
    }

    func testAutomaticEnqueuePreservesExplicitRequestsAndUnfinishedOpeningBuffers() {
        let explicit = job(.explicit)
        XCTAssertEqual(OfflinePreparationRecovery.automaticJob(explicit, committedChunks: 42), explicit)
        var buffer = job(.demandWindow)
        buffer.maximumChunkCount = 2
        XCTAssertEqual(OfflinePreparationRecovery.automaticJob(buffer, committedChunks: 1), buffer)
        let automatic = OfflinePreparationRecovery.automaticJob(buffer, committedChunks: 2)
        XCTAssertEqual(automatic.policy, .whileCharging)
        XCTAssertNil(automatic.maximumChunkCount)
        XCTAssertEqual(automatic.id, buffer.id)
    }
}
