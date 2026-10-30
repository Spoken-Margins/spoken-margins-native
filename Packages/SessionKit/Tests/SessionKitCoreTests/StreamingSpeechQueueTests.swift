import XCTest
@testable import SessionKit

@MainActor
final class StreamingSpeechQueueTests: XCTestCase {
    func testQueueReportsStartedOnlyAfterTheSpeechClientConfirmsPlayback() async throws {
        let audio = PendingStartAudioClient()
        let queue = StreamingSpeechQueue(speech: audio)
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
        let queue = StreamingSpeechQueue(speech: audio)
        queue.configureSpeechClient(audio)
        let stopsAfterConfigure = audio.stopCount

        queue.pauseForInterjection()
        XCTAssertEqual(audio.stopCount, stopsAfterConfigure, "no streamed speech is playing, so nothing may be stopped")
        queue.resumeAfterInterjection()
    }

    func testStartingAMarginStopsStreamedSpeechTheQueueIsDriving() async throws {
        let audio = StopCountingAudioClient()
        let queue = StreamingSpeechQueue(speech: audio)
        queue.configureSpeechClient(audio)
        queue.enqueue(["A streamed response sentence."], turnId: "turn-001")
        try await waitUntil { audio.playCount > 0 } // the queue is speaking, so the Margin has something to stop (#1894)
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

// MARK: Order, offsets and hand-offs

extension StreamingSpeechQueueTests {
    func testSentencesPlayInOrderWithOffsetsThatSkipBlankTextAndTrimEdges() async throws {
        let audio = ScriptedAudioClient()
        let queue = StreamingSpeechQueue(speech: audio)
        var observations: [StreamingSpeechQueue.PlaybackObservation] = []
        var drained: [String] = []
        queue.onPlaybackObservation = { observations.append($0) }
        queue.onTurnDrained = { drained.append($0) }

        queue.enqueue(["  First one. ", "   ", "Second."], turnId: "turn-a")
        try await waitUntil { drained == ["turn-a"] }

        XCTAssertEqual(audio.played, ["stream:turn-a:0", "stream:turn-a:1"])
        XCTAssertEqual(audio.prepared, ["First one.", "Second."])
        XCTAssertEqual(observations, [
            .init(event: .started, turnId: "turn-a", charOffset: 0),
            .init(event: .progressed, turnId: "turn-a", charOffset: 10),
            .init(event: .started, turnId: "turn-a", charOffset: 11),
            .init(event: .progressed, turnId: "turn-a", charOffset: 18)
        ])
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertFalse(queue.hasPendingSpeech(for: "turn-a"))
    }

    func testOffsetsKeepCountingWhenALaterBatchJoinsTheSameTurn() async throws {
        let audio = ScriptedAudioClient()
        let queue = StreamingSpeechQueue(speech: audio)
        var started: [Int] = []
        var drained: [String] = []
        queue.onPlaybackObservation = { if $0.event == .started { started.append($0.charOffset) } }
        queue.onTurnDrained = { drained.append($0) }

        queue.enqueue(["Hello."], turnId: "turn-b")
        try await waitUntil { drained.count == 1 }
        queue.enqueue(["World."], turnId: "turn-b")
        try await waitUntil { drained.count == 2 }

        XCTAssertEqual(started, [0, 7])
        XCTAssertEqual(audio.played, ["stream:turn-b:0", "stream:turn-b:1"])
    }

    func testAFailedStartIsReportedAndTheTurnStillDrains() async throws {
        let audio = ScriptedAudioClient()
        audio.startStatus = .failed("test")
        let queue = StreamingSpeechQueue(speech: audio)
        var observations: [StreamingSpeechQueue.PlaybackObservation] = []
        var drained: [String] = []
        queue.onPlaybackObservation = { observations.append($0) }
        queue.onTurnDrained = { drained.append($0) }

        queue.enqueue(["Will not start."], turnId: "turn-c")
        try await waitUntil { drained == ["turn-c"] }

        XCTAssertEqual(observations, [.init(event: .failed, turnId: "turn-c", charOffset: 0)])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testPausingForAMarginKeepsTheSpeakingSentenceAndResumingPlaysItAgain() async throws {
        let audio = ScriptedAudioClient()
        audio.startStatus = .pending
        let queue = StreamingSpeechQueue(speech: audio)
        queue.enqueue(["Interrupted sentence."], turnId: "turn-d")
        try await waitUntil { audio.played.count == 1 }

        queue.pauseForInterjection()
        XCTAssertTrue(queue.isPausedForInterjection)
        XCTAssertEqual(queue.pendingCount, 1, "the sentence that was speaking waits for the Margin to finish")
        XCTAssertEqual(queue.currentTurnId, "turn-d")
        XCTAssertEqual(queue.currentSentenceStartOffset, 0)
        XCTAssertEqual(audio.stopCount, 1)

        var drained: [String] = []
        queue.onTurnDrained = { drained.append($0) }
        audio.startStatus = .confirmed
        queue.resumeAfterInterjection()
        try await waitUntil { drained == ["turn-d"] }

        XCTAssertFalse(queue.isPausedForInterjection)
        XCTAssertEqual(audio.prepared, ["Interrupted sentence.", "Interrupted sentence."])
    }

    func testHandingOverToCanonicalPlaybackClearsTheQueueWithoutStoppingTheSharedClient() async throws {
        let audio = ScriptedAudioClient()
        audio.startStatus = .pending
        let queue = StreamingSpeechQueue(speech: audio)
        var drained: [String] = []
        queue.onTurnDrained = { drained.append($0) }
        queue.enqueue(["One.", "Two."], turnId: "turn-e")
        try await waitUntil { audio.played.count == 1 }

        queue.relinquishToCanonicalPlayback()

        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertNil(queue.currentTurnId)
        XCTAssertFalse(queue.isPausedForInterjection)
        XCTAssertEqual(audio.stopCount, 0, "the session engine owns the client now")
        audio.startStatus = .confirmed
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(audio.played.count, 1, "the cancelled worker plays nothing more")
        XCTAssertTrue(drained.isEmpty)
    }

    func testStopAndClearStopsTheClientAndRestartsNumbering() async throws {
        let audio = ScriptedAudioClient()
        audio.startStatus = .pending
        let queue = StreamingSpeechQueue(speech: audio)
        queue.enqueue(["One.", "Two."], turnId: "turn-f")
        try await waitUntil { audio.played.count == 1 }

        queue.stopAndClear()

        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(queue.pendingCount, 0)
        audio.startStatus = .confirmed
        var started: [Int] = []
        var drained: [String] = []
        queue.onPlaybackObservation = { if $0.event == .started { started.append($0.charOffset) } }
        queue.onTurnDrained = { drained.append($0) }
        queue.enqueue(["Fresh."], turnId: "turn-f")
        try await waitUntil { drained == ["turn-f"] }
        XCTAssertEqual(started, [0])
        XCTAssertEqual(audio.played.last, "stream:turn-f:0")
    }

    /// #1895: Margin capture pauses and resumes the queue in one synchronous run when the recorder won't start. The
    /// worker the pause cancelled used to wake after the resume and clear the new worker's handle, so the next
    /// enqueue started a second worker and two sentences spoke at once.
    func testPausingAndResumingInOneRunNeverLetsTwoSentencesSpeakAtOnce() async throws {
        let audio = OverlapCountingAudioClient()
        let queue = StreamingSpeechQueue(speech: audio)
        var drained: [String] = []
        queue.onTurnDrained = { drained.append($0) }
        queue.enqueue(["One."], turnId: "turn-g")
        try await waitUntil { audio.playedTargets.count == 1 }

        queue.pauseForInterjection()
        queue.resumeAfterInterjection()   // no await between: the cancelled worker has not woken yet
        try await Task.sleep(for: .milliseconds(150))
        queue.enqueue(["Two.", "Three."], turnId: "turn-g")
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(audio.playedTargets, ["stream:turn-g:0", "stream:turn-g:0"], "One plays again after the resume; Two waits for it")
        XCTAssertEqual(audio.maxActive, 1, "only one sentence speaks at a time")

        audio.finish("stream:turn-g:0")
        try await waitUntil { audio.playedTargets.count == 3 }
        XCTAssertEqual(audio.playedTargets.last, "stream:turn-g:1")
        XCTAssertEqual(audio.maxActive, 1)
        audio.finish("stream:turn-g:1")
        try await waitUntil { audio.playedTargets.count == 4 }
        audio.finish("stream:turn-g:2")
        try await waitUntil { drained == ["turn-g"] }
        XCTAssertEqual(audio.playedTargets, ["stream:turn-g:0", "stream:turn-g:0", "stream:turn-g:1", "stream:turn-g:2"])
        XCTAssertEqual(audio.maxActive, 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
    }
}

/// Starts, finishes and records like the real client would, on whatever status the test sets.
private final class ScriptedAudioClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var status = PlaybackStartStatus.confirmed
    private var preparedTexts: [String] = []
    private var playedTargets: [String] = []
    private var stops = 0

    var startStatus: PlaybackStartStatus {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }
    var prepared: [String] { lock.withLock { preparedTexts } }
    var played: [String] { lock.withLock { playedTargets } }
    var stopCount: Int { lock.withLock { stops } }

    func prepareSpeechText(_ text: String) throws -> String {
        lock.withLock { preparedTexts.append(text) }
        return text
    }
    func play(targetId: String) throws { lock.withLock { playedTargets.append(targetId) } }
    func pause() throws {}
    func stop() throws { lock.withLock { stops += 1 } }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }
    func isPlaybackComplete(targetId: String) -> Bool { true }
}

/// Speaks every sentence until the test finishes it, and counts how many were speaking at once.
private final class OverlapCountingAudioClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [String] = []
    private var active: Set<String> = []
    private var finished: Set<String> = []
    private var peak = 0

    var playedTargets: [String] { lock.withLock { played } }
    var maxActive: Int { lock.withLock { peak } }

    func finish(_ targetId: String) {
        lock.withLock {
            finished.insert(targetId)
            active.remove(targetId)
        }
    }

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {
        lock.withLock {
            played.append(targetId)
            finished.remove(targetId)
            active.insert(targetId)
            peak = max(peak, active.count)
        }
    }
    func pause() throws {}
    func stop() throws { lock.withLock { active.removeAll() } }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .confirmed }
    func isPlaybackComplete(targetId: String) -> Bool { lock.withLock { finished.contains(targetId) } }
}
