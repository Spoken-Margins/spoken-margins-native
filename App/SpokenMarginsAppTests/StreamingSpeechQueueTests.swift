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
