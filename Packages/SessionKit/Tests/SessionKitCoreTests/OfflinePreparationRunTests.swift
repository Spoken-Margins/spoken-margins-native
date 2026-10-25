import XCTest
@testable import SessionKit

/// #905, #1107: how a Make available offline run waits out a heat pause or a memory backoff.
final class OfflinePreparationRunTests: XCTestCase {
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
