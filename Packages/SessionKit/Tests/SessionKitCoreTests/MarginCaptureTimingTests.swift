import Foundation
import XCTest
@testable import SessionKit

final class MarginCaptureTimingTests: XCTestCase {
    private let request = MarginCaptureRequest(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001506")!,
        tappedAt: Date(timeIntervalSince1970: 0), uptime: 100
    )

    func testBluetoothMilestonesAreMeasuredFromTapNotRecorderOrHealthThreshold() {
        var timing = MarginCaptureTiming(request: request)
        timing.recorderRequested(at: 100.2)
        timing.recorderStarted(at: 101.246, inputRoute: "BluetoothHFP")
        timing.observe(.init(recorderRunning: true, capturedMs: 20, peakPowerDb: -160),
                       at: 101.3, inputRoute: "BluetoothHFP")
        timing.observe(.init(recorderRunning: true, capturedMs: 40, peakPowerDb: -30),
                       at: 101.5, inputRoute: "BluetoothHFP")
        let fields = timing.fields
        XCTAssertEqual(fields["captureID"], request.id.uuidString)
        XCTAssertEqual(fields["tapAt"], "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(fields["tapToRecorderRequestedMs"], "200")
        XCTAssertEqual(fields["tapToRecorderStartedMs"], "1246")
        XCTAssertEqual(fields["tapToFirstAudioObservedMs"], "1300")
        XCTAssertEqual(fields["tapToFirstNonSilentObservedMs"], "1500", "a recorder start or silent audio isn't speech arriving")
        XCTAssertEqual(fields["firstNonSilentInputRoute"], "BluetoothHFP")
        XCTAssertEqual(fields["firstAudioTimingMethod"], "recorder_clock_poll_upper_bound")
        XCTAssertEqual(fields["firstNonSilentTimingMethod"], "meter_poll_upper_bound")
        XCTAssertEqual(fields["startTone"], "not_used")
        XCTAssertEqual(fields["tapToStartToneFinishedMs"], "not_applicable")
    }

    func testMissingSilentStoppedOrInvalidReadingsNeverInventFirstNonSilentInput() {
        var timing = MarginCaptureTiming(request: request)
        timing.recorderStarted(at: 100.1, inputRoute: "BuiltInMic")
        let readings: [RecordingCaptureReading?] = [
            nil,
            .init(recorderRunning: true, capturedMs: 0, peakPowerDb: -10),
            .init(recorderRunning: false, capturedMs: 500, peakPowerDb: -10),
            .init(recorderRunning: true, capturedMs: 20),
            .init(recorderRunning: true, capturedMs: 20, peakPowerDb: -.infinity),
            .init(recorderRunning: true, capturedMs: 20, peakPowerDb: .nan),
            .init(recorderRunning: true, capturedMs: 20, peakPowerDb: -160),
            .init(recorderRunning: true, capturedMs: 20, peakPowerDb: -120)
        ]
        for reading in readings {
            timing.observe(reading, at: 100.2, inputRoute: "BuiltInMic")
        }
        XCTAssertEqual(timing.fields["tapToFirstNonSilentObservedMs"], "not_observed")
        XCTAssertEqual(timing.fields["firstNonSilentInputRoute"], "not_observed")
    }

    func testFirstWordsBeforeRecorderStartedAreNotReportedAsCaptured() {
        var timing = MarginCaptureTiming(request: request)
        timing.observe(.init(recorderRunning: true, capturedMs: 50, peakPowerDb: -20), at: 100.05, inputRoute: "BuiltInMic")
        XCTAssertEqual(timing.fields["tapToFirstAudioObservedMs"], "not_observed")
        XCTAssertEqual(timing.fields["tapToRecorderStartedMs"], "not_observed")
    }

    func testRetryAndRouteChangesKeepFirstMilestonesAndANewCaptureStartsFresh() {
        var timing = MarginCaptureTiming(request: request)
        timing.recorderRequested(at: 100.01)
        timing.recorderStarted(at: 100.08, inputRoute: "BuiltInMic")
        timing.observe(.init(recorderRunning: true, capturedMs: 50, peakPowerDb: -50), at: 100.12, inputRoute: "BuiltInMic")
        let first = timing.fields
        timing.recorderRequested(at: 103)
        timing.recorderStarted(at: 104, inputRoute: "BluetoothHFP")
        timing.observe(.init(recorderRunning: true, capturedMs: 50, peakPowerDb: -20), at: 104.1, inputRoute: "BluetoothHFP")
        XCTAssertEqual(timing.fields, first)
        let next = MarginCaptureTiming(request: .init(tappedAt: request.tappedAt + 10, uptime: 110))
        XCTAssertNotEqual(next.fields["captureID"], first["captureID"])
        XCTAssertEqual(next.fields["tapToFirstNonSilentObservedMs"], "not_observed")
    }

    func testPermissionWaitCountsAndDurationsUseUptimeInsteadOfWallClock() {
        var timing = MarginCaptureTiming(request: request)
        timing.recorderRequested(at: 130)
        timing.recorderStarted(at: 130.1, inputRoute: "BuiltInMic")
        XCTAssertEqual(timing.fields["tapToRecorderStartedMs"], "30100")
        XCTAssertEqual(timing.fields["tapAt"], "1970-01-01T00:00:00.000Z")
    }
}
