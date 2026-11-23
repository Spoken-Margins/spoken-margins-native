import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio

/// The iOS voice stand-in the client tests hand to `SupertonicSpeechPlaybackClient` (#4691). A copy of the
/// app test target's, which the tests that stay app-hosted still use.
final class RecordingFallbackAudioClient: AudioPlaybackClient, SpokenProgressReporting, @unchecked Sendable {
    var preparedText = ""
    var playedOffsets: [Int] = []
    var playbackRates: [Double] = []
    var mixingStates: [Bool] = []
    var backgroundAudioStates: [Bool] = []
    var playbackVolumes: [Float] = []
    var pauseCount = 0
    var offset = 0
    /// How far the place moves each time it is read, as a speaking voice's would.
    var advancesPerRead = 0
    var completedTargetId: String?
    /// Words started, as the iOS voice counts them; nil for a voice that can't count them.
    var spokenWords: Int?
    var wordsPerRead = 0
    /// How many times the place was asked for: the stall monitor asks once per sample (#4313).
    private(set) var progressReads = 0
    /// Set to make the iOS voice refuse to start, as a session that can't be activated would.
    var playError: Error?
    /// What the iOS voice says about having begun: `.pending` is speech queued that never started.
    var startStatus: PlaybackStartStatus = .confirmed
    var stopCount = 0
    /// Plays ("play:<offset>"), pauses and stops in the order they happened, with anything else the test
    /// records into it (an audio session activation), so a test can check the order of a recovery (APA-05).
    var events: [String] { eventLock.withLock { recordedEvents } }
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []
    func record(_ event: String) { eventLock.withLock { recordedEvents.append(event) } }

    func prepareSpeechText(_ text: String) throws -> String {
        preparedText = text
        return text
    }

    func isPlaybackComplete(targetId: String) -> Bool { completedTargetId == targetId }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }

    func stop() throws { stopCount += 1; record("stop") }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        if let playError { throw playError }
        offset = charOffset
        playedOffsets.append(charOffset)
        record("play:\(charOffset)")
    }

    func currentCharOffset() -> Int? {
        defer { offset += advancesPerRead }
        return offset
    }

    func spokenProgress() -> Int? {
        progressReads += 1
        defer { spokenWords = spokenWords.map { $0 + wordsPerRead } }
        return spokenWords
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRates.append(rate)
    }

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixingStates.append(enabled)
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        backgroundAudioStates.append(enabled)
    }

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

    func pause() throws {
        pauseCount += 1
        record("pause")
    }
}
