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

    func testExpiryMarksMatchingExplicitRequestsWithoutChangingTheirPlace() throws {
        var explicit = job(.explicit)
        explicit.requestedAt = Date(timeIntervalSince1970: 10)
        explicit.nextChunkIndex = 42
        explicit.userPriority = -2
        let key = OfflinePreparationRun.RequestKey(jobId: explicit.id, requestedAt: explicit.requestedAt)
        var second = explicit
        second.id = "second"
        let secondKey = OfflinePreparationRun.RequestKey(jobId: second.id, requestedAt: second.requestedAt)
        let interruptedJobs = OfflinePreparationRecovery.interruptedJobs(
            [job(.whileCharging), job(.demandWindow), explicit, second, job(.explicit, cancelled: true)],
            requests: [key, secondKey]
        )
        XCTAssertEqual(interruptedJobs.map(\.id), [explicit.id, second.id])
        XCTAssertTrue(interruptedJobs.allSatisfy { $0.lastFailureCode == OfflinePreparationRecovery.waitingForSystem })
        let interrupted = try XCTUnwrap(interruptedJobs.first)
        XCTAssertEqual(interrupted.lastFailureCode, OfflinePreparationRecovery.waitingForSystem)
        var expected = explicit
        expected.lastFailureCode = OfflinePreparationRecovery.waitingForSystem
        XCTAssertEqual(interrupted, expected, "request identity, committed progress and priority survive expiry")
        explicit.requestedAt = Date(timeIntervalSince1970: 20)
        XCTAssertTrue(OfflinePreparationRecovery.interruptedJobs([explicit], requests: [key]).isEmpty,
                      "an old expiration must not affect a newer tap")
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
