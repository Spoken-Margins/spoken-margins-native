import Foundation
import XCTest
@testable import SessionKit

final class BackgroundPreparationPlannerTests: XCTestCase {
    private let ready = BackgroundPreparationPlanner.Environment(
        thermalIsSerious: false, lowPowerMode: false, episodeTaskIsRunning: false
    )

    private func episode(_ id: String = "e", policy: PreparationJobPolicy = .explicit,
                         time: TimeInterval = 0, stage: EpisodeMapPreparationStage = .verifySource,
                         cancelled: Bool = false) -> EpisodeMapPreparationJob {
        .init(id: id, itemId: "item-\(id)", policy: policy,
              requestedAt: Date(timeIntervalSince1970: time), stage: stage,
              nextUnitIndex: 7, isCancelled: cancelled)
    }

    private func eligible(_ jobs: [EpisodeMapPreparationJob],
                          policy: AutomaticEpisodeMapPreparationPolicy = .whileCharging,
                          local: (String) -> Bool = { _ in true }) -> [EpisodeMapPreparationJob] {
        BackgroundPreparationPlanner.eligibleEpisodeJobs(jobs, episodePolicy: policy, hasLocalAudio: local)
    }

    func testExplicitEpisodesPrecedeAutomaticThenSortByRequestedAt() {
        let jobs = [episode("automatic", policy: .whileCharging), episode("late", time: 2), episode("early", time: 1)]
        XCTAssertEqual(eligible(jobs).map(\.id), ["early", "late", "automatic"])
        XCTAssertEqual(eligible(jobs, policy: .off).map(\.id), ["early", "late"])
    }

    func testCancelledAndCompletedJobsAreIgnored() {
        let jobs = [episode("cancelled", cancelled: true), episode("completed", stage: .completed), episode("live")]
        XCTAssertEqual(eligible(jobs).map(\.id), ["live"])
        let audio = [AudioPreparationJob(id: "cancelled", itemId: "a", manifestId: "m", policy: .explicit, isCancelled: true)]
        XCTAssertEqual(BackgroundPreparationPlanner.progressToken(audioJobs: audio, episodeJobs: jobs),
                       ["episode:live:verify_source:7"])
    }

    func testEpisodeWithoutLocalAudioIsIgnored() {
        XCTAssertEqual(eligible([episode("missing"), episode("local")], local: { $0 == "item-local" }).map(\.id), ["local"])
    }

    func testPassesAlternateAndEpisodeOnlyWorkStillRuns() {
        var planner = BackgroundPreparationPlanner()
        let jobs = [episode()]
        XCTAssertEqual(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready)?.id, "e")
        planner.afterEpisodePass()
        XCTAssertNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        XCTAssertNotNil(planner.plan(hasAudioWork: false, episodeJobs: jobs, environment: ready))
        XCTAssertTrue(planner.afterAudioPass(audioHasMore: true, hadAudioWork: true, hadEpisodeJobs: true))
        XCTAssertNotNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        planner.afterEpisodePass()
        XCTAssertTrue(planner.afterAudioPass(audioHasMore: false, hadAudioWork: false, hadEpisodeJobs: true))
        XCTAssertNotNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        planner.afterEpisodePass()
        XCTAssertTrue(planner.afterAudioPass(audioHasMore: true, hadAudioWork: false, hadEpisodeJobs: true))
        XCTAssertNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        XCTAssertFalse(planner.afterAudioPass(audioHasMore: false, hadAudioWork: false, hadEpisodeJobs: false))
        XCTAssertNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        XCTAssertFalse(planner.afterAudioPass(audioHasMore: false, hadAudioWork: true, hadEpisodeJobs: false))
        XCTAssertNotNil(planner.plan(hasAudioWork: true, episodeJobs: jobs, environment: ready))
        XCTAssertNil(planner.plan(hasAudioWork: false, episodeJobs: [], environment: ready))
    }

    func testThermalOrLowPowerConditionsSelectAudio() {
        let planner = BackgroundPreparationPlanner()
        for environment in [
            BackgroundPreparationPlanner.Environment(thermalIsSerious: true, lowPowerMode: false, episodeTaskIsRunning: false),
            BackgroundPreparationPlanner.Environment(thermalIsSerious: false, lowPowerMode: true, episodeTaskIsRunning: false)
        ] {
            XCTAssertNil(planner.plan(hasAudioWork: false, episodeJobs: [episode()], environment: environment))
        }
    }

    func testRunningEpisodeTaskSelectsAudio() {
        let environment = BackgroundPreparationPlanner.Environment(
            thermalIsSerious: false, lowPowerMode: false, episodeTaskIsRunning: true
        )
        XCTAssertNil(BackgroundPreparationPlanner().plan(hasAudioWork: false, episodeJobs: [episode()], environment: environment))
    }

    func testProgressDeterminesRetryOrContinue() {
        XCTAssertEqual(BackgroundPreparationPlanner.result(hasRemainingWork: true, before: ["a"], after: ["a"]), .retryLater)
        XCTAssertEqual(BackgroundPreparationPlanner.result(hasRemainingWork: true, before: ["a"], after: ["b"]), .continueNow)
    }

    func testNoRemainingWorkFinishesWithoutReadingProgress() {
        var reads = 0
        func read() -> [String] { reads += 1; return ["changed"] }
        XCTAssertEqual(BackgroundPreparationPlanner.result(hasRemainingWork: false, before: [], after: read()), .finished)
        XCTAssertEqual(reads, 0)
    }

    func testTokenPrefixesFieldOrderSortingAndResultCaseNamesStayIdentical() {
        let audio = ["z", "a"].map {
            AudioPreparationJob(id: $0, itemId: "item", manifestId: "manifest", policy: .explicit, nextChunkIndex: 3)
        }
        XCTAssertEqual(BackgroundPreparationPlanner.progressToken(audioJobs: audio, episodeJobs: [episode("z", stage: .renderBridges), episode("a")]),
                       ["audio:a:3", "audio:z:3", "episode:a:verify_source:7", "episode:z:render_bridges:7"])
        let results: [BackgroundPreparationWorkResult] = [.finished, .continueNow, .retryLater]
        XCTAssertEqual(results.map { String(describing: $0) }, ["finished", "continueNow", "retryLater"])
        XCTAssertEqual(results.map(\.hasRemainingWork), [false, true, true])
    }
}
