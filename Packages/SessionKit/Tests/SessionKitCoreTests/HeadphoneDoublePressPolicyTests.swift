import XCTest
@testable import SessionKit

final class HeadphoneDoublePressPolicyTests: XCTestCase {
    private func decide(_ s: HeadphoneRemoteSignal, _ a: HeadphoneDoublePressAction, _ r: Bool) -> HeadphoneDoublePressDecision {
        HeadphoneDoublePressPolicy.decide(signal: s, setting: a, isRecording: r)
    }

    func testNextTrackAddsMarginWhenIdleAndSettingIsAddMargin() {
        XCTAssertEqual(decide(.nextTrack, .addMargin, false), .startMargin)
    }

    func testNextTrackSkipsForwardWhenSettingRestoresSkip() {
        XCTAssertEqual(decide(.nextTrack, .skipForward, false), .skipForward)
    }

    func testNextTrackEndsRecordingWhateverTheSetting() {
        XCTAssertEqual(decide(.nextTrack, .addMargin, true), .endMargin)
        XCTAssertEqual(decide(.nextTrack, .skipForward, true), .endMargin)
    }

    func testSkipForwardCommandAlwaysSkipsWhenIdle() {
        XCTAssertEqual(decide(.skipForward, .addMargin, false), .skipForward)
        XCTAssertEqual(decide(.skipForward, .skipForward, false), .skipForward)
    }

    func testSkipForwardCommandEndsRecording() {
        XCTAssertEqual(decide(.skipForward, .addMargin, true), .endMargin)
    }

    func testOtherSignalsPassThrough() {
        for setting in HeadphoneDoublePressAction.allCases {
            for recording in [false, true] {
                XCTAssertEqual(decide(.other, setting, recording), .passThrough)
            }
        }
    }

    func testSignalFromOrigin() {
        XCTAssertEqual(HeadphoneRemoteSignal(origin: "now_playing_live_speech_next_track"), .nextTrack)
        XCTAssertEqual(HeadphoneRemoteSignal(origin: "now_playing_live_speech"), .skipForward)
        XCTAssertEqual(HeadphoneRemoteSignal(origin: "compact_url"), .skipForward)
    }

    func testSettingDefaultsToAddMarginAndParsesStoredValues() {
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: nil), .addMargin)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: "garbage"), .addMargin)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: "skipForward"), .skipForward)
    }
}
