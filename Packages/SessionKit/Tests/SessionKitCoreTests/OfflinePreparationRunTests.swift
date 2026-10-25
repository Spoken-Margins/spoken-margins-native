import XCTest
@testable import SessionKit

/// #905: what a Make available offline run asks iOS for, what the progress banner says, and how a
/// heat pause ends.
final class OfflinePreparationRunTests: XCTestCase {
    private func job(
        _ policy: PreparationJobPolicy = .explicit,
        _ state: PreparedAudioState = .preparing,
        done: Int,
        of planned: Int
    ) -> OfflinePreparationRun.Job {
        OfflinePreparationRun.Job(policy: policy, state: state, completedChunks: done, plannedChunks: planned)
    }

    // MARK: Progress

    func testProgressCountsOnlyExplicitJobsThatStillHaveChunksToMake() {
        let jobs = [
            job(.explicit, .preparing, done: 36, of: 129),
            job(.explicit, .pausedForThermal, done: 4, of: 20),
            job(.explicit, .notPrepared, done: 0, of: 10),
            job(.demandWindow, .preparing, done: 1, of: 2),
            job(.whileCharging, .preparing, done: 50, of: 300),
            job(.explicit, .readyOffline, done: 8, of: 8),
            job(.explicit, .failed, done: 3, of: 12),
            job(.explicit, .stopped, done: 3, of: 12),
            job(.explicit, .needsRepreparation, done: 3, of: 12)
        ]
        XCTAssertEqual(
            OfflinePreparationRun.explicitProgress(jobs),
            OfflinePreparationRun.Progress(completedChunks: 40, totalChunks: 159)
        )
        XCTAssertEqual(OfflinePreparationRun.explicitProgress(jobs).remainingChunks, 119)
    }

    func testProgressClampsOddCountsAndHandlesAnEmptyQueue() {
        XCTAssertEqual(OfflinePreparationRun.explicitProgress([]), .init(completedChunks: 0, totalChunks: 0))
        let odd = [job(done: 20, of: 10), job(done: -3, of: 5), job(done: 2, of: -4)]
        XCTAssertEqual(OfflinePreparationRun.explicitProgress(odd), .init(completedChunks: 10, totalChunks: 15))
        XCTAssertEqual(OfflinePreparationRun.Progress(completedChunks: 9, totalChunks: 4).remainingChunks, 0)
    }

    // MARK: Asking iOS

    func testAskedForOnlyWhenTheAppIsOnScreenAndTheRunIsLongEnough() {
        let long = OfflinePreparationRun.Progress(completedChunks: 36, totalChunks: 129)
        XCTAssertTrue(OfflinePreparationRun.shouldRequestContinuedProcessing(long, alreadyRequested: false, appIsActive: true, preparationAllowed: true))
        XCTAssertFalse(
            OfflinePreparationRun.shouldRequestContinuedProcessing(long, alreadyRequested: false, appIsActive: false, preparationAllowed: true),
            "iOS takes the request only while the app is on screen"
        )
        XCTAssertFalse(
            OfflinePreparationRun.shouldRequestContinuedProcessing(long, alreadyRequested: true, appIsActive: true, preparationAllowed: true),
            "one request covers the queue"
        )
        XCTAssertFalse(
            OfflinePreparationRun.shouldRequestContinuedProcessing(long, alreadyRequested: false, appIsActive: true, preparationAllowed: false),
            "no card while speech playback or a restored session holds the Library back (#2694)"
        )
    }

    func testShortRunsAndEmptyQueuesGetNoBanner() {
        let minimum = OfflinePreparationRun.minimumChunksForContinuedProcessing
        for remaining in 0..<minimum {
            let progress = OfflinePreparationRun.Progress(completedChunks: 10, totalChunks: 10 + remaining)
            XCTAssertFalse(
                OfflinePreparationRun.shouldRequestContinuedProcessing(progress, alreadyRequested: false, appIsActive: true, preparationAllowed: true),
                "\(remaining) chunks left"
            )
        }
        let atMinimum = OfflinePreparationRun.Progress(completedChunks: 0, totalChunks: minimum)
        XCTAssertTrue(OfflinePreparationRun.shouldRequestContinuedProcessing(atMinimum, alreadyRequested: false, appIsActive: true, preparationAllowed: true))
        XCTAssertFalse(OfflinePreparationRun.shouldRequestContinuedProcessing(.init(completedChunks: 0, totalChunks: 0), alreadyRequested: false, appIsActive: true, preparationAllowed: true))
    }

    func testAnOpeningBufferAloneNeverAsksForContinuedProcessing() {
        let progress = OfflinePreparationRun.explicitProgress([job(.demandWindow, .preparing, done: 0, of: 2), job(.whileCharging, .preparing, done: 0, of: 400)])
        XCTAssertEqual(progress.totalChunks, 0)
        XCTAssertFalse(OfflinePreparationRun.shouldRequestContinuedProcessing(progress, alreadyRequested: false, appIsActive: true, preparationAllowed: true))
    }

    // MARK: Requests iOS or the listener ended

    private func request(_ id: String, at seconds: TimeInterval, done: Int = 0, of planned: Int = 100) -> OfflinePreparationRun.Job {
        OfflinePreparationRun.Job(
            id: id, requestedAt: Date(timeIntervalSince1970: seconds),
            policy: .explicit, state: .preparing, completedChunks: done, plannedChunks: planned
        )
    }

    func testARequestTheBackgroundTimeWasEndedForIsNotAskedForAgain() {
        let jobs = [request("job-a", at: 1_000, done: 10), request("job-b", at: 2_000, done: 0, of: 50)]
        let declined = OfflinePreparationRun.openExplicitRequests([jobs[0]])
        XCTAssertEqual(OfflinePreparationRun.explicitProgress(jobs, excluding: declined), .init(completedChunks: 0, totalChunks: 50))
        XCTAssertEqual(OfflinePreparationRun.explicitProgress(jobs), .init(completedChunks: 10, totalChunks: 150), "the banner still counts every open job")
    }

    func testTappingMakeAvailableOfflineAgainIsANewRequest() {
        let first = request("job-a", at: 1_000, done: 10)
        let declined = OfflinePreparationRun.openExplicitRequests([first])
        let tappedAgain = request("job-a", at: 5_000, done: 10)
        XCTAssertEqual(
            OfflinePreparationRun.explicitProgress([tappedAgain], excluding: declined),
            .init(completedChunks: 10, totalChunks: 100),
            "the same job with a new request time is asked for again"
        )
        XCTAssertEqual(OfflinePreparationRun.explicitProgress([first], excluding: declined), .init(completedChunks: 0, totalChunks: 0))
    }

    func testOnlyOpenExplicitRequestsAreRemembered() {
        let jobs = [
            request("job-a", at: 1),
            OfflinePreparationRun.Job(id: "job-b", requestedAt: Date(timeIntervalSince1970: 2), policy: .demandWindow, state: .preparing, completedChunks: 0, plannedChunks: 2),
            OfflinePreparationRun.Job(id: "job-c", requestedAt: Date(timeIntervalSince1970: 3), policy: .explicit, state: .failed, completedChunks: 1, plannedChunks: 9)
        ]
        XCTAssertEqual(
            OfflinePreparationRun.openExplicitRequests(jobs),
            [OfflinePreparationRun.RequestKey(jobId: "job-a", requestedAt: Date(timeIntervalSince1970: 1))]
        )
    }

    // MARK: Banner words

    func testBannerSaysHowFarTheRunIsAndWhenItIsWaitingForTheHeat() {
        let progress = OfflinePreparationRun.Progress(completedChunks: 36, totalChunks: 129)
        XCTAssertEqual(OfflinePreparationRun.continuedSubtitle(progress, phase: .preparing), "36 of 129")
        XCTAssertEqual(
            OfflinePreparationRun.continuedSubtitle(progress, phase: .coolingDown),
            "Paused while the phone cools · 36 of 129"
        )
        XCTAssertEqual(OfflinePreparationRun.continuedSubtitle(.init(completedChunks: 0, totalChunks: 0), phase: .preparing), "Finishing")
    }

    // MARK: Heat wait

    func testNothingQueuedMeansNothingToWaitFor() {
        for thermal in [SpeechThermalLevel.nominal, .fair, .serious, .critical] {
            for waited in [0, 45, 3_600] {
                XCTAssertEqual(
                    OfflinePreparationRun.heatWaitStep(thermal: thermal, waitedSeconds: waited, foregroundWorkWaiting: false),
                    .stop(.noWorkWaiting),
                    "\(thermal) after \(waited)s"
                )
            }
        }
    }

    func testAHotPhoneIsRecheckedQuicklyAtFirstThenEveryMinute() {
        let expected: [(waited: Int, seconds: Int)] = [(0, 15), (45, 15), (59, 15), (60, 30), (299, 30), (300, 60), (1_500, 60), (1_799, 60)]
        for thermal in [SpeechThermalLevel.serious, .critical] {
            for (waited, seconds) in expected {
                XCTAssertEqual(
                    OfflinePreparationRun.heatWaitStep(thermal: thermal, waitedSeconds: waited, foregroundWorkWaiting: true),
                    .wait(seconds: seconds),
                    "\(thermal) after \(waited)s"
                )
            }
        }
    }

    func testTheWaitEndsAfterHalfAnHourOfHeat() {
        XCTAssertEqual(OfflinePreparationRun.maximumHeatWaitSeconds, 1_800)
        for waited in [1_800, 1_860, 7_200] {
            XCTAssertEqual(
                OfflinePreparationRun.heatWaitStep(thermal: .critical, waitedSeconds: waited, foregroundWorkWaiting: true),
                .stop(.waitedTooLong),
                "after \(waited)s"
            )
        }
    }

    func testFairHeatLetsTheRunGoOnAfterAWaitAndNominalToo() {
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            XCTAssertEqual(
                OfflinePreparationRun.heatWaitStep(thermal: thermal, waitedSeconds: 15, foregroundWorkWaiting: true),
                .resume,
                "\(thermal) after a wait"
            )
        }
    }

    func testAPassThatStoppedWithoutHeatIsNotRetried() {
        // The pass rendered nothing, but the phone is not hot: it stopped for another reason (no
        // voice, live speech owns the renderer, a failure). Looping on that would spin.
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            XCTAssertEqual(
                OfflinePreparationRun.heatWaitStep(thermal: thermal, waitedSeconds: 0, foregroundWorkWaiting: true),
                .stop(.notHeat)
            )
        }
    }

    /// The owner's 2026-10-08 export: the run stopped for heat and the phone read nominal at export,
    /// because nothing started the run again. Played through the policy, the run waits and resumes.
    func testARunThatStoppedForHeatResumesOnItsOwnOnceThePhoneCools() {
        var thermals: [SpeechThermalLevel] = [.serious, .serious, .serious, .serious, .fair]
        var waited = 0
        var steps: [OfflinePreparationRun.HeatWaitStep] = []
        while !thermals.isEmpty {
            let step = OfflinePreparationRun.heatWaitStep(thermal: thermals.removeFirst(), waitedSeconds: waited, foregroundWorkWaiting: true)
            steps.append(step)
            guard case .wait(let seconds) = step else { break }
            waited += seconds
        }
        XCTAssertEqual(steps, [.wait(seconds: 15), .wait(seconds: 15), .wait(seconds: 15), .wait(seconds: 15), .resume])
        XCTAssertEqual(waited, 60)
    }

    func testAPhoneThatStaysHotStopsTheWaitInsideTheLimit() {
        var waited = 0
        var rechecks = 0
        while case .wait(let seconds) = OfflinePreparationRun.heatWaitStep(thermal: .serious, waitedSeconds: waited, foregroundWorkWaiting: true) {
            waited += seconds
            rechecks += 1
            if rechecks >= 100 { break }
        }
        XCTAssertLessThan(rechecks, 100, "the wait must end")
        XCTAssertGreaterThanOrEqual(waited, OfflinePreparationRun.maximumHeatWaitSeconds)
        XCTAssertLessThan(waited, OfflinePreparationRun.maximumHeatWaitSeconds + 60)
        XCTAssertEqual(
            OfflinePreparationRun.heatWaitStep(thermal: .serious, waitedSeconds: waited, foregroundWorkWaiting: true),
            .stop(.waitedTooLong)
        )
    }

    // MARK: Memory backoff wait (#1107)

    func testHeatWaitStepIsThePauseWaitStepWithoutABackoff() {
        for thermal in [SpeechThermalLevel.nominal, .fair, .serious, .critical] {
            for waited in [0, 15, 300, 1_800] {
                for work in [true, false] {
                    XCTAssertEqual(
                        OfflinePreparationRun.heatWaitStep(thermal: thermal, waitedSeconds: waited, foregroundWorkWaiting: work),
                        OfflinePreparationRun.pauseWaitStep(thermal: thermal, memoryBackoffActive: false, waitedSeconds: waited, foregroundWorkWaiting: work)
                    )
                }
            }
        }
    }

    func testABackoffThatIsActiveIsWaitedOutEvenOnACoolPhone() {
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            XCTAssertEqual(
                OfflinePreparationRun.pauseWaitStep(thermal: thermal, memoryBackoffActive: true, waitedSeconds: 0, foregroundWorkWaiting: true),
                .wait(seconds: 15),
                "\(thermal) at the start of the wait"
            )
        }
    }

    func testABackoffIsRecheckedAtTheQuickPaceTheWholeWait() {
        for waited in [0, 15, 59, 60, 299, 300, 599] {
            XCTAssertEqual(
                OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: true, waitedSeconds: waited, foregroundWorkWaiting: true),
                .wait(seconds: OfflinePreparationRun.memoryRecheckSeconds),
                "after \(waited)s"
            )
        }
    }

    func testAnEndedBackoffResumesTheRunAfterAWait() {
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            XCTAssertEqual(
                OfflinePreparationRun.pauseWaitStep(thermal: thermal, memoryBackoffActive: false, waitedSeconds: 15, foregroundWorkWaiting: true),
                .resume,
                "\(thermal) once the backoff is over"
            )
        }
    }

    func testAPassThatStoppedWithoutABackoffOrHeatIsNotRetried() {
        XCTAssertEqual(
            OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: false, waitedSeconds: 0, foregroundWorkWaiting: true),
            .stop(.notHeat)
        )
    }

    func testNothingQueuedMeansNothingToWaitForDuringABackoff() {
        for waited in [0, 45, 3_600] {
            XCTAssertEqual(
                OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: true, waitedSeconds: waited, foregroundWorkWaiting: false),
                .stop(.noWorkWaiting),
                "after \(waited)s"
            )
        }
    }

    func testABackoffThatKeepsBeingRenewedStopsTheWaitInsideTheLimit() {
        XCTAssertEqual(OfflinePreparationRun.maximumMemoryWaitSeconds, 600)
        var waited = 0
        var rechecks = 0
        while case .wait(let seconds) = OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: true, waitedSeconds: waited, foregroundWorkWaiting: true) {
            waited += seconds
            rechecks += 1
            if rechecks >= 100 { break }
        }
        XCTAssertLessThan(rechecks, 100, "the wait must end")
        XCTAssertGreaterThanOrEqual(waited, OfflinePreparationRun.maximumMemoryWaitSeconds)
        XCTAssertLessThan(waited, OfflinePreparationRun.maximumMemoryWaitSeconds + 60)
        XCTAssertEqual(
            OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: true, waitedSeconds: waited, foregroundWorkWaiting: true),
            .stop(.waitedTooLong)
        )
    }

    func testHeatKeepsItsLongerLimitWhileABackoffIsAlsoActive() {
        XCTAssertEqual(
            OfflinePreparationRun.pauseWaitStep(thermal: .serious, memoryBackoffActive: true, waitedSeconds: 900, foregroundWorkWaiting: true),
            .wait(seconds: 60),
            "heat is still holding the run after the memory limit"
        )
        XCTAssertEqual(
            OfflinePreparationRun.pauseWaitStep(thermal: .serious, memoryBackoffActive: true, waitedSeconds: 1_800, foregroundWorkWaiting: true),
            .stop(.waitedTooLong)
        )
    }

    /// A warning, then a run that waits the 60 second backoff out in 15 second steps and goes on.
    func testARunThatStoppedForAMemoryWarningResumesOnItsOwnWhenTheBackoffEnds() {
        var backoff: [Bool] = [true, true, true, true, false]
        var waited = 0
        var steps: [OfflinePreparationRun.HeatWaitStep] = []
        while !backoff.isEmpty {
            let step = OfflinePreparationRun.pauseWaitStep(thermal: .nominal, memoryBackoffActive: backoff.removeFirst(), waitedSeconds: waited, foregroundWorkWaiting: true)
            steps.append(step)
            guard case .wait(let seconds) = step else { break }
            waited += seconds
        }
        XCTAssertEqual(steps, [.wait(seconds: 15), .wait(seconds: 15), .wait(seconds: 15), .wait(seconds: 15), .resume])
        XCTAssertEqual(waited, 60)
    }
}
