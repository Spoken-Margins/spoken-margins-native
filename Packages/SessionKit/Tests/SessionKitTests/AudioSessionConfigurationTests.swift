import XCTest
@testable import SessionKitAudio

/// `setCategory` is a synchronous round trip to the audio server, so a playback start only calls it when the session
/// is not already in the wanted configuration (#2511). A wrong "already right" would leave a Margin voice without its
/// ducking or a recording's category in place; a wrong "differs" only costs the round trip the helper exists to save.
final class AudioSessionConfigurationTests: XCTestCase {
    private func config(
        category: String = "AVAudioSessionCategoryPlayback",
        mode: String = "AVAudioSessionModeSpokenAudio",
        options: UInt = 0x2
    ) -> AudioSessionConfiguration {
        AudioSessionConfiguration(category: category, mode: mode, optionsRawValue: options)
    }

    /// #2967: the live-speech Now Playing job runs off the main thread, so it can start after the recorder has
    /// switched the session. It must leave a capturing session alone, or the Margin records nothing.
    func testRecordingCategoriesAreCapturingAndPlaybackIsNot() {
        XCTAssertTrue(config(category: "AVAudioSessionCategoryPlayAndRecord").isCapturing)
        XCTAssertTrue(config(category: "AVAudioSessionCategoryRecord").isCapturing)
        XCTAssertFalse(config().isCapturing)
        XCTAssertFalse(config(category: "AVAudioSessionCategoryAmbient").isCapturing)
    }

    func testSameConfigurationSkipsTheCall() {
        XCTAssertFalse(AudioSessionConfiguration.needsCategoryChange(current: config(), wanted: config()))
    }

    func testEachDifferingFieldForcesTheCall() {
        let base = config()
        XCTAssertTrue(AudioSessionConfiguration.needsCategoryChange(
            current: config(category: "AVAudioSessionCategoryPlayAndRecord"), wanted: base), "a recording left its category")
        XCTAssertTrue(AudioSessionConfiguration.needsCategoryChange(
            current: config(mode: "AVAudioSessionModeDefault"), wanted: base))
        XCTAssertTrue(AudioSessionConfiguration.needsCategoryChange(
            current: config(options: 0x1), wanted: base), "mixing and ducking changed")
        XCTAssertTrue(AudioSessionConfiguration.needsCategoryChange(
            current: config(options: 0), wanted: base))
    }

    func testAnUnreadableSessionIsAlwaysSet() {
        XCTAssertTrue(AudioSessionConfiguration.needsCategoryChange(current: nil, wanted: config()))
    }
}
