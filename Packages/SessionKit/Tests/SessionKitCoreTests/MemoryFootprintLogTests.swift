import Foundation
import XCTest
@testable import SessionKit

final class MemoryFootprintLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20Z

    func testKeepsTheLastTwentySamplesNewestLast() {
        var log = MemoryFootprintLog()
        for index in 0..<25 {
            log.record(.playback, mediaType: "text", footprintBytes: UInt64(index) * 1_048_576,
                       availableBytes: nil, at: start.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(log.samples.count, 20)
        XCTAssertEqual(log.samples.first?.footprintBytes, 5 * 1_048_576, "the five oldest samples are dropped")
        XCTAssertEqual(log.samples.last?.footprintBytes, 24 * 1_048_576)
    }

    func testPlaybackChangesAreLabelledStartThenSwitchAndIgnorePauseAndResume() {
        var log = MemoryFootprintLog()
        log.record(.launch, mediaType: nil, footprintBytes: 1, availableBytes: nil, at: start)

        XCTAssertNil(log.eventForPlayback(itemId: "podcast-1", isPlaying: false), "opening an item without playing it")
        XCTAssertEqual(log.eventForPlayback(itemId: "podcast-1", isPlaying: true), .itemStart)
        XCTAssertNil(log.eventForPlayback(itemId: "podcast-1", isPlaying: false), "pause")
        XCTAssertNil(log.eventForPlayback(itemId: "podcast-1", isPlaying: true), "resume of the same item")
        XCTAssertNil(log.eventForPlayback(itemId: "article-1", isPlaying: false), "switching items while paused")
        XCTAssertEqual(log.eventForPlayback(itemId: "article-1", isPlaying: true), .itemSwitch)
        XCTAssertEqual(log.eventForPlayback(itemId: "podcast-1", isPlaying: true), .itemSwitch)
        XCTAssertNil(log.eventForPlayback(itemId: nil, isPlaying: true))

        log.record(.launch, mediaType: nil, footprintBytes: 1, availableBytes: nil, at: start)
        XCTAssertEqual(log.eventForPlayback(itemId: "podcast-1", isPlaying: true), .itemStart,
                       "the first item after a relaunch is a start")
    }

    func testPlaybackSampleIsDueAMinuteAfterTheLastSample() {
        var log = MemoryFootprintLog()
        XCTAssertTrue(log.playbackSampleIsDue(at: start), "an empty log takes a sample")
        log.record(.itemStart, mediaType: "podcast", footprintBytes: 1, availableBytes: nil, at: start)
        XCTAssertFalse(log.playbackSampleIsDue(at: start.addingTimeInterval(59.5)))
        XCTAssertTrue(log.playbackSampleIsDue(at: start.addingTimeInterval(60)))
        XCTAssertTrue(log.playbackSampleIsDue(at: start.addingTimeInterval(-5)), "the clock went backwards")
    }

    func testDiagnosticsLineShowsEventMediaTypeAndSizesButNoTitles() {
        var log = MemoryFootprintLog()
        log.record(.launch, mediaType: nil, footprintBytes: 150 * 1_048_576, availableBytes: 2_900 * 1_048_576, at: start)
        log.record(.itemSwitch, mediaType: "text", footprintBytes: 412 * 1_048_576 + 700_000,
                   availableBytes: nil, at: start.addingTimeInterval(62))
        log.record(.memoryWarning, mediaType: "The Astra+Sol Thread Workflow", footprintBytes: 1_900 * 1_048_576,
                   availableBytes: 80 * 1_048_576, at: start.addingTimeInterval(3_600))

        XCTAssertEqual(log.diagnosticsLine, [
            "09-21 14:13:20Z launch none 150MB free 2900MB",
            "09-21 14:14:22Z item_switch text 413MB",
            "09-21 15:13:20Z memory_warning other 1900MB free 80MB",
        ].joined(separator: " | "))
    }

    func testSamplesSurviveASaveAndLoad() throws {
        var log = MemoryFootprintLog()
        log.record(.itemStart, mediaType: "podcast", footprintBytes: 300 * 1_048_576, availableBytes: 9, at: start)
        let reloaded = try JSONDecoder().decode(MemoryFootprintLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(reloaded.samples, log.samples)
    }

    // The shape of MXMetricPayload.jsonRepresentation(), trimmed to the sections read here.
    private let recordedPayload = """
    {
      "appVersion" : "0.1",
      "timeStampBegin" : "2026-09-30 00:00:00 +0000",
      "timeStampEnd" : "2026-09-30 23:59:00 +0000",
      "cpuMetrics" : { "cumulativeCPUTime" : "1200 sec" },
      "applicationExitMetrics" : {
        "backgroundExitData" : {
          "cumulativeAppWatchdogExitCount" : 0,
          "cumulativeMemoryResourceLimitExitCount" : 1,
          "cumulativeMemoryPressureExitCount" : 3,
          "cumulativeNormalAppExitCount" : 4,
          "cumulativeSuspendedWithLockedFileExitCount" : 0
        },
        "foregroundExitData" : {
          "cumulativeBadAccessExitCount" : 0,
          "cumulativeMemoryResourceLimitExitCount" : 2,
          "cumulativeNormalAppExitCount" : 5,
          "cumulativeAppWatchdogExitCount" : 0
        }
      }
    }
    """

    func testReadsMemoryExitCountsFromARecordedPayload() throws {
        let counts = try XCTUnwrap(MemoryExitCounts(metricPayloadJSON: Data(recordedPayload.utf8)))
        XCTAssertEqual(counts.foregroundMemoryLimit, 2)
        XCTAssertEqual(counts.backgroundMemoryLimit, 1)
        XCTAssertEqual(counts.backgroundMemoryPressure, 3)
        XCTAssertEqual(counts.diagnosticsLine,
                       "foreground 2 · background 1 · background system pressure 3 · 2026-09-30 to 2026-09-30")
    }

    func testMissingExitFieldsReadNotReportedInsteadOfZero() throws {
        let partial = """
        { "applicationExitMetrics" : { "foregroundExitData" : { "cumulativeMemoryResourceLimitExitCount" : 0 } } }
        """
        let counts = try XCTUnwrap(MemoryExitCounts(metricPayloadJSON: Data(partial.utf8)))
        XCTAssertEqual(counts.diagnosticsLine,
                       "foreground 0 · background not reported · background system pressure not reported")
        XCTAssertNil(MemoryExitCounts(metricPayloadJSON: Data(#"{"cpuMetrics":{}}"#.utf8)),
                     "a report without an app-exit section")
        XCTAssertNil(MemoryExitCounts(metricPayloadJSON: Data("not json".utf8)))
    }
}
