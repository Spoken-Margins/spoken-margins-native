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

    /// #2957: a listener who never chose gets skip forward, and an explicit Add a Margin is honored.
    func testSettingDefaultsToSkipForwardAndHonorsAStoredAddMargin() {
        XCTAssertEqual(HeadphoneDoublePressAction.default, .skipForward)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: nil), .skipForward)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: ""), .skipForward)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: "garbage"), .skipForward)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: "skipForward"), .skipForward)
        XCTAssertEqual(HeadphoneDoublePressAction(storedValue: "addMargin"), .addMargin)
    }

    func testAFreshInstallDoubleTapSkipsForward() {
        let setting = HeadphoneDoublePressAction(storedValue: nil)
        XCTAssertEqual(decide(.nextTrack, setting, false), .skipForward)
    }
}
