import Foundation
import XCTest
@testable import SessionKit

final class MemoryFootprintVerdictTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// One sample per step: (event, media type, megabytes), a minute apart.
    private func samples(_ steps: [(MemoryFootprintLog.Event, String, UInt64)]) -> [MemoryFootprintLog.Sample] {
        var log = MemoryFootprintLog()
        var samples: [MemoryFootprintLog.Sample] = []
        for (index, step) in steps.enumerated() {
            log.record(step.0, mediaType: step.1, footprintBytes: step.2 * 1_048_576, availableBytes: nil,
                       at: start.addingTimeInterval(Double(index) * 60))
            samples.append(log.samples.last!)
        }
        return samples
    }

    /// The issue's run: a podcast for two minutes, an article for three, then switches back and forth.
    private func switches(textAt textMegabytes: [UInt64], podcastAt podcastMegabytes: [UInt64],
                          textPlayback: (UInt64) -> [UInt64] = { [$0 + 2, $0 + 1, $0 + 2] }) -> [MemoryFootprintLog.Sample] {
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
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 340, 345, 338], podcastAt: [330, 335, 332]))
        XCTAssertEqual(verdict, .steady(switches: 7, playbackMinutes: 8))
        XCTAssertEqual(verdict.diagnosticsLine, "steady since launch: 7 switches, 8 playback minutes measured")
    }

    func testTheFirstSwitchIntoATypeLoadingItsEngineIsNotGrowth() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 400, 402], podcastAt: [390, 391]))
        if case .growingPerSwitch = verdict { XCTFail("the voice loading at the first switch into text is not a leak") }
    }

    func testMemoryLeftBehindAtEachSwitchIntoTextIsGrowthPerSwitch() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 340, 380, 420], podcastAt: [100, 100, 100]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaType: "text", megabytesPerSwitch: 40))
        XCTAssertEqual(verdict.diagnosticsLine, "growing 40MB per switch into text")
    }

    func testMemoryLeftBehindAtEachSwitchIntoThePodcastIsGrowthPerSwitch() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [300, 300, 300, 300], podcastAt: [330, 360, 390]))
        XCTAssertEqual(verdict, .growingPerSwitch(mediaType: "podcast", megabytesPerSwitch: 30))
    }

    func testGrowthJustUnderTheSwitchThresholdIsSteady() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100, 300, 309, 318], podcastAt: [300, 300, 300]))
        if case .growingPerSwitch = verdict { XCTFail("9 MB a switch is under the 10 MB threshold") }
    }

    func testMemoryClimbingWhileTheArticlePlaysIsGrowthPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [300], podcastAt: [],
                                                              textPlayback: { [$0 + 50, $0 + 70, $0 + 90, $0 + 110] }))
        XCTAssertEqual(verdict, .growingPerMinute(mediaType: "text", megabytesPerMinute: 20))
        XCTAssertEqual(verdict.diagnosticsLine, "growing 20MB per minute playing text")
    }

    func testTheLoadingJumpInTheFirstMinuteIsNotGrowthPerMinute() {
        let verdict = MemoryFootprintVerdict(samples: switches(textAt: [100], podcastAt: [],
                                                              textPlayback: { _ in [480, 482, 479] }))
        XCTAssertEqual(verdict, .steady(switches: 1, playbackMinutes: 2), "the 100 → 480 MB jump happens before the first playback sample")
    }

    func testOnlySamplesSinceTheLastLaunchCount() {
        var before = switches(textAt: [100, 340, 380, 420], podcastAt: [100, 100, 100])
        before += samples([(.launch, "none", 6), (.itemStart, "text", 300)])
        XCTAssertEqual(MemoryFootprintVerdict(samples: before), .tooFewSamples, "the growth before the relaunch is a closed chapter")
    }

    func testAFewSamplesSayNothing() {
        XCTAssertEqual(MemoryFootprintVerdict(samples: []), .tooFewSamples)
        XCTAssertEqual(MemoryFootprintVerdict(samples: samples([(.itemStart, "podcast", 90), (.playback, "podcast", 400)])),
                       .tooFewSamples)
        XCTAssertEqual(MemoryFootprintVerdict.tooFewSamples.diagnosticsLine, "too few samples since launch")
    }

    func testAMemoryWarningInsideAStretchDoesNotSplitIt() {
        let verdict = MemoryFootprintVerdict(samples: samples([
            (.itemStart, "text", 300), (.playback, "text", 320), (.memoryWarning, "text", 330),
            (.playback, "text", 340), (.playback, "text", 360),
        ]))
        XCTAssertEqual(verdict, .growingPerMinute(mediaType: "text", megabytesPerMinute: 13))
    }
}
