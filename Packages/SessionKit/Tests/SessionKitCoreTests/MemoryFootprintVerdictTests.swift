import Foundation
import XCTest
@testable import SessionKit

final class MemoryFootprintVerdictTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// One sample per step: (event, media type, megabytes), a minute apart.
    private func samples(_ steps: [(MemoryFootprintLog.Event, String, UInt64)]) -> [MemoryFootprintLog.Sample] {
        timed(steps.enumerated().map { ($0.element.0, $0.element.1, $0.element.2, Double($0.offset)) })
    }

    /// One sample per step: (event, media type, megabytes, minutes from the start).
    private func timed(_ steps: [(MemoryFootprintLog.Event, String, UInt64, Double)]) -> [MemoryFootprintLog.Sample] {
        var log = MemoryFootprintLog()
        var samples: [MemoryFootprintLog.Sample] = []
        for step in steps {
            log.record(step.0, mediaType: step.1, footprintBytes: step.2 * 1_048_576, availableBytes: nil,
                       at: start.addingTimeInterval(step.3 * 60))
            samples.append(log.samples.last!)
        }
        return samples
    }

    /// The issue's run: a podcast for two minutes, an article for six, then switches back and forth.
    private func switches(textAt textMegabytes: [UInt64], podcastAt podcastMegabytes: [UInt64],
                          textPlayback: (UInt64) -> [UInt64] = { [$0 + 2, $0 + 1, $0 + 2, $0 + 1, $0 + 2, $0 + 1] })
        -> [MemoryFootprintLog.Sample] {
        var steps: [(MemoryFootprintLog.Event, String, UInt64)] = [(.launch, "none", 20), (.itemStart, "podcast", 90),
                                                                (.playback, "podcast", 92), (.playback, "podcast", 91)]
        for (index, text) in textMegabytes.enumerated() {
            steps.append((.itemSwitch, "text", text))
            steps += textPlayback(text).map { (.playback, "text", $0) }
            if index < podcastMegabytes.count { steps.append((.itemSwitch, "podcast", podcastMegabytes[index])) }
        }
        return samples(steps)
    }

    func testSteadySwitchesAndPlaybackReadSteady() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 340, 345, 338, 342, 340],
                                                              podcastAt: [330, 335, 332, 336, 333]))
        XCTAssertEqual(verdict, .steady(switches: 11, playbackMinutes: 30))
        XCTAssertEqual(verdict.diagnosticsLine, "steady: 11 switches, 30 playback minutes measured")
    }

    func testTheFirstSwitchIntoATypeLoadingItsEngineIsNotGrowth() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 400, 402, 401, 403, 402],
                                                              podcastAt: [390, 391, 390, 392, 391]))
        XCTAssertEqual(verdict, .steady(switches: 11, playbackMinutes: 30), "the voice loading at the first switch into text is not a leak")
    }

    func testMemoryLeftBehindAtEachSwitchIntoTextIsGrowthPerSwitch() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 340, 380, 420, 460, 500],
                                                              podcastAt: [100, 100, 100, 100, 100]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaTypes: ["text"], megabytesPerSwitch: 40))
        XCTAssertEqual(verdict.diagnosticsLine, "growing 40MB per switch into text")
    }

    func testMemoryLeftBehindAtEachSwitchIntoThePodcastIsGrowthPerSwitch() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [300, 300, 300, 300, 300, 300],
                                                              podcastAt: [330, 360, 390, 420, 450]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaTypes: ["podcast"], megabytesPerSwitch: 30))
    }

    /// Memory one item leaves behind is already in the footprint as the next item starts, so when listening alternates
    /// it shows in both types' switches. The verdict names both rather than guessing which one leaves it.
    func testGrowthThatShowsInBothTypesNamesBoth() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 340, 380, 420, 460, 500],
                                                              podcastAt: [330, 375, 420, 465, 510]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaTypes: ["podcast", "text"], megabytesPerSwitch: 45))
        XCTAssertEqual(verdict.diagnosticsLine, "growing 45MB per switch into podcast and text")
    }

    func testGrowthJustUnderTheSwitchThresholdIsSteady() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 300, 309, 318, 327, 336],
                                                              podcastAt: [300, 300, 300, 300, 300]))
        XCTAssertEqual(verdict, .steady(switches: 11, playbackMinutes: 30), "9 MB a switch is under the 10 MB threshold")
    }

    func testGrowthAtTheSwitchThresholdIsGrowth() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 300, 310, 320, 330, 340],
                                                              podcastAt: [300, 300, 300, 300, 300]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaTypes: ["text"], megabytesPerSwitch: 10))
    }

    /// No playback stretches, so the switches alone decide it.
    func testOneReloadAmongSteadySwitchesIsNotGrowth() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 300, 302, 500, 503, 505],
                                                              podcastAt: [90, 90, 90, 90, 90], textPlayback: { _ in [] }))
        XCTAssertEqual(verdict, .steady(switches: 11, playbackMinutes: 0),
                       "one 198 MB jump among +2, +3 and +2 is a reload, not memory left behind each time")
    }

    func testTheSwitchesAfterMemoryWarningsReloadAndAreNotGrowth() {
        // The app unloads its voices on a warning: 300 → 150 MB, then the next article reloads the voice to 450 MB.
        // Read without the warnings, the text switches would climb 150 MB four times.
        var steps: [(MemoryFootprintLog.Event, String, UInt64)] = [
            (.itemStart, "text", 100), (.itemSwitch, "podcast", 90), (.itemSwitch, "text", 300),
        ]
        for reloaded: UInt64 in [450, 600, 750, 900] {
            steps += [(.memoryWarning, "text", 150), (.itemSwitch, "podcast", 90), (.itemSwitch, "text", reloaded)]
        }
        steps += [(.itemSwitch, "podcast", 90), (.itemSwitch, "text", 902)]
        let verdict = MemoryFootprintVerdict(samples: samples(steps))
        XCTAssertEqual(verdict, .tooFewSamples, "each reload after a warning starts the measuring over: \(verdict)")
    }

    /// The measured run on Supertonic (main-t3 at c9e5697, 2026-11-22), in MB at each switch from the podcast's start:
    /// the voice loads during the first article (112 → 363), settles over the next two (410, 428), then holds.
    private let recordedSupertonicSwitches: [UInt64] = [116, 112, 363, 361, 410, 428, 428, 429]

    /// The measured run's switches, the podcast first and alternating with the article, `perType` into each:
    /// the recorded ones, then the footprint holding where the recording ended, with `leakPerRound` MB more left behind
    /// at each round after the first.
    private func measuredRun(perType: Int, leakPerRound: UInt64 = 0) -> [MemoryFootprintLog.Sample] {
        let recorded = recordedSupertonicSwitches
        let footprints = (0..<(2 * perType)).map { index -> UInt64 in
            let base = index < recorded.count ? recorded[index] : recorded[recorded.count - 2 + index % 2]
            return base + UInt64(index / 2) * leakPerRound
        }
        let steps = footprints.enumerated().map { index, megabytes -> (MemoryFootprintLog.Event, String, UInt64) in
            (index == 0 ? .itemStart : .itemSwitch, index % 2 == 0 ? "transcript_backed_media" : "text", megabytes)
        }
        return samples([(.launch, "none", 111)] + steps)
    }

    /// Four switches into each type leave two changes, both in the warm-up: the first lane run read them as 18 MB per
    /// switch. Two changes can't tell settling from memory left behind, so they say nothing.
    func testFourSwitchesAreTooFewToTellTheVoiceWarmUpFromGrowth() {
        XCTAssertEqual(MemoryFootprintVerdict(samples: measuredRun(perType: 4)), .tooFewSamples)
    }

    func testTheMeasuredRunSeesPastTheVoiceWarmUp() {
        let perType = MemoryFootprintVerdict.switchesPerTypeInMeasuredRun
        XCTAssertLessThanOrEqual(1 + 2 * perType, MemoryFootprintLog.capacity, "the launch and every switch must fit the log")
        let verdict = MemoryFootprintVerdict(samples: measuredRun(perType: perType))
        XCTAssertEqual(verdict, .steady(switches: 2 * perType - 1, playbackMinutes: 0),
                       "363 → 410 → 428 MB and then holding is the voice settling, not memory left behind: \(verdict)")
    }

    func testTheMeasuredRunStillCatchesMemoryLeftBehindEachRound() {
        let verdict = MemoryFootprintVerdict(samples: measuredRun(perType: MemoryFootprintVerdict.switchesPerTypeInMeasuredRun,
                                                                  leakPerRound: 30))
        guard case .growingPerSwitch = verdict else {
            return XCTFail("30 MB left behind each round must read as growth, warm-up or not: \(verdict)")
        }
    }

    func testMemoryClimbingWhileTheArticlePlaysIsGrowthPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [300], podcastAt: [], textPlayback: {
            [$0 + 50, $0 + 70, $0 + 90, $0 + 110, $0 + 130, $0 + 150]
        }))
        XCTAssertEqual(verdict, .growingPerMinute(mediaType: "text", megabytesPerMinute: 20))
        XCTAssertEqual(verdict.diagnosticsLine, "growing 20MB per minute playing text")
    }

    func testTheLoadingJumpInTheFirstMinuteIsNotGrowthPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100], podcastAt: [],
                                                              textPlayback: { _ in [480, 482, 479, 481, 480, 478] }))
        XCTAssertEqual(verdict, .steady(switches: 1, playbackMinutes: 5), "the 100 → 480 MB jump happens before the first playback sample")
    }

    /// One high reading at the end of a stretch moves a first-to-last difference; the slope across all of them barely.
    func testOneHighReadingAtTheEndIsNotGrowthPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100], podcastAt: [],
                                                              textPlayback: { _ in [400, 401, 400, 399, 400, 430] }))
        XCTAssertEqual(verdict, .steady(switches: 1, playbackMinutes: 5))
    }

    func testAShortWobbleIsNotMeasuredPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100], podcastAt: [], textPlayback: { _ in [400, 405, 410] }))
        XCTAssertEqual(verdict, .tooFewSamples, "10 MB over two minutes is too short a stretch to call a climb")
    }

    func testAPauseSplitsAStretchAndIsNotPlayback() {
        let first = (0..<6).map { (MemoryFootprintLog.Event.playback, "text", UInt64(300), Double(1 + $0)) }
        let second = (0..<6).map { (MemoryFootprintLog.Event.playback, "text", UInt64(330), Double(40 + $0)) }
        let verdict = MemoryFootprintVerdict(samples: timed([(.itemStart, "text", 100, 0)] + first + second))
        XCTAssertEqual(verdict, .steady(switches: 0, playbackMinutes: 10), "the 34 paused minutes are not playback")
    }

    func testOnlySamplesSinceTheLastLaunchCount() {
        var before = switches(textAt: [100, 340, 380, 420, 460, 500], podcastAt: [100, 100, 100, 100, 100])
        before += samples([(.launch, "none", 6), (.itemStart, "text", 300)])
        XCTAssertEqual(MemoryFootprintVerdict(samples: before), .tooFewSamples, "the growth before the relaunch is a closed chapter")
    }

    func testAFewSamplesSayNothing() {
        XCTAssertEqual(MemoryFootprintVerdict(samples: []), .tooFewSamples)
        XCTAssertEqual(MemoryFootprintVerdict(samples: samples([(.itemStart, "podcast", 90), (.playback, "podcast", 400)])),
                       .tooFewSamples)
        XCTAssertEqual(MemoryFootprintVerdict.tooFewSamples.diagnosticsLine, "too few samples to say")
    }

    func testAMemoryWarningInsideAStretchDoesNotSplitIt() {
        let verdict = MemoryFootprintVerdict(samples: samples([
            (.itemStart, "text", 300), (.playback, "text", 320), (.memoryWarning, "text", 330),
            (.playback, "text", 360), (.playback, "text", 380), (.playback, "text", 400), (.playback, "text", 420),
            (.playback, "text", 440),
        ]))
        XCTAssertEqual(verdict, .growingPerMinute(mediaType: "text", megabytesPerMinute: 20))
    }
}
