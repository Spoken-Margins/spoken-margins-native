import SessionKit
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class StreamingSpeechQueueTests: XCTestCase {
    func testQueueReportsStartedOnlyAfterTheSpeechClientConfirmsPlayback() async throws {
        let audio = PendingStartAudioClient()
        let queue = StreamingSpeechQueue()
        var observations: [StreamingSpeechQueue.PlaybackObservation] = []
        queue.configureSpeechClient(audio)
        queue.onPlaybackObservation = { observations.append($0) }

        queue.enqueue(["A rendered response sentence."], turnId: "turn-response-001")
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(observations.isEmpty)

        audio.confirmPlaybackStart()
        for _ in 0..<20 where observations.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(observations.first?.event, .started)
        XCTAssertEqual(observations.first?.turnId, "turn-response-001")
        XCTAssertEqual(observations.first?.charOffset, 0)
        queue.stopAndClear()
    }
}

extension StreamingSpeechQueueTests {
    func testStartingAMarginDoesNotStopPlaybackTheQueueIsNotSpeaking() {
        // The queue's speech client is the shared router: stop() there also stops a playing podcast.
        let audio = StopCountingAudioClient()
        let queue = StreamingSpeechQueue()
        queue.configureSpeechClient(audio)
        let stopsAfterConfigure = audio.stopCount

        queue.pauseForInterjection()
        XCTAssertEqual(audio.stopCount, stopsAfterConfigure, "no streamed speech is playing, so nothing may be stopped")
        queue.resumeAfterInterjection()
    }

    func testStartingAMarginStopsStreamedSpeechTheQueueIsDriving() async throws {
        let audio = StopCountingAudioClient()
        let queue = StreamingSpeechQueue()
        queue.configureSpeechClient(audio)
        queue.enqueue(["A streamed response sentence."], turnId: "turn-001")
        for _ in 0..<20 where audio.playCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopsBeforeMargin = audio.stopCount

        queue.pauseForInterjection()
        XCTAssertEqual(audio.stopCount, stopsBeforeMargin + 1)
        queue.stopAndClear()
    }
}

private final class StopCountingAudioClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var plays = 0
    var stopCount: Int { lock.withLock { stops } }
    var playCount: Int { lock.withLock { plays } }

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { lock.withLock { plays += 1 } }
    func pause() throws {}
    func stop() throws { lock.withLock { stops += 1 } }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .pending }
}

private final class PendingStartAudioClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var startStatus = PlaybackStartStatus.pending

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func pause() throws {}

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        lock.withLock { startStatus }
    }

    func confirmPlaybackStart() {
        lock.withLock { startStatus = .confirmed }
    }
}
