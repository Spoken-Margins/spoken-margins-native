import AVFoundation
import SessionKitAudio
import XCTest

/// Plays a known passage out loud and lets the Mac hear it (#1790): the lane records the Simulator's output
/// through BlackHole and checks that it played, didn't stall, didn't repeat itself, and said the right words.
/// It runs only when a /lane T3 request names it (it is in the AudioAdapters plan); elsewhere it skips.
///
/// What it can't catch: the Lock Screen, background audio and Bluetooth on a real phone, heat fallbacks,
/// the phone's own installed voices, and whether the voice sounds good. Those stay on the owner's phone.
final class AudioLoopbackPlaybackTests: XCTestCase {
    static let passage = """
        The quick brown fox jumps over the lazy dog. Spoken Margins plays every word once. \
        A listener can leave a note in the margin and hear it again later.
        """

    /// The iOS voice is what a fresh install reads articles with in the Simulator (Supertonic is a download,
    /// and an unaccepted terms sheet falls back to it). This plays through the app's own adapter, at full volume.
    @MainActor  // XCTContext activities (the verdict's attachment) need the main thread
    func testIOSVoiceSpeaksThePassageOnceWithoutGaps() async throws {
        executionTimeAllowance = 180  // the plan's maximum: a cold speech service (#1230), the window and its check
        try await SystemVoiceRuntime.requireAnsweringVoice()  // loads the speech service before the window opens
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: 0.5)
        defer { try? client.stop() }
        _ = try client.prepareSpeechText(Self.passage)

        let window = try AudioLoopbackWindow.open(for: self, seconds: 25, expected: Self.passage,
                                                  limits: .init(maxStall: 2.0, minSound: 4.0, maxWER: 0.25))
        try await window.waitUntilRecording()
        try client.play(targetId: "passage", from: 0)
        let deadline = ContinuousClock.now + .seconds(24)
        while !client.isPlaybackComplete(targetId: "passage"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(client.isPlaybackComplete(targetId: "passage"), "the iOS voice finished the passage inside the window")
        try window.require(try await window.verdict())
    }
}
