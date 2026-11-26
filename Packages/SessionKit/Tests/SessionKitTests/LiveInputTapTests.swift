import XCTest
@testable import SessionKitAudio

/// #3940, PR 0 of the Design: the live tap runs beside the recorder, so its start and stop must balance however a
/// Margin ends. A tap left running holds the microphone with no recording to match; a late start after Cancel does
/// the same. These tests drive the lifecycle with a fake session, the boundary the real `SpeechLiveInputSession` is
/// kept behind.
final class LiveInputTapTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [(kind: String, fields: [String: String])] = []
        private var storedWords: [[LiveInputWord]] = []

        func event(_ kind: String, _ fields: [String: String]) { lock.withLock { storedEvents.append((kind, fields)) } }
        func words(_ batch: [LiveInputWord]) { lock.withLock { storedWords.append(batch) } }
        var events: [(kind: String, fields: [String: String])] { lock.withLock { storedEvents } }
        var kinds: [String] { events.map(\.kind) }
        var words: [[LiveInputWord]] { lock.withLock { storedWords } }
    }

    private final class FakeSession: LiveInputSession, @unchecked Sendable {
        let words: AsyncStream<LiveInputResult>
        private let continuation: AsyncStream<LiveInputResult>.Continuation
        private let lock = NSLock()
        private var started = 0
        private var stopped = 0
        private let startError: LiveInputUnavailable?
        private let startGate: AsyncStream<Void>?

        /// `startGate`: the start waits for a value on it, so a test can send Cancel while the start is in flight.
        init(startError: LiveInputUnavailable? = nil, startGate: AsyncStream<Void>? = nil) {
            let (stream, continuation) = AsyncStream<LiveInputResult>.makeStream()
            self.words = stream
            self.continuation = continuation
            self.startError = startError
            self.startGate = startGate
        }

        var startCount: Int { lock.withLock { started } }
        var stopCount: Int { lock.withLock { stopped } }

        func start() async throws {
            lock.withLock { started += 1 }
            if let startGate { for await _ in startGate { break } }
            if let startError { throw startError }
        }

        func stop() async {
            lock.withLock { stopped += 1 }
            continuation.finish()
        }

        func say(_ batch: [LiveInputWord]) {
            continuation.yield(LiveInputResult(words: batch, startMs: batch.first?.startMs, isFinal: batch.first?.isFinal ?? false))
        }
    }

    private func makeTap(
        _ session: FakeSession,
        _ recorder: Recorder,
        wall: @escaping @Sendable () -> Int = { 0 },
        cpu: @escaping @Sendable () -> Int = { 0 }
    ) -> LiveInputTap {
        LiveInputTap(
            makeSession: { session },
            onWords: recorder.words,
            onEvent: recorder.event,
            wallClockMs: wall,
            cpuClockMs: cpu
        )
    }

    private func word(_ text: String, _ startMs: Int, final: Bool = true) -> LiveInputWord {
        LiveInputWord(text: text, startMs: startMs, endMs: startMs + 300, isFinal: final)
    }

    func testAStartThatReturnedIsMatchedByExactlyOneStopWhateverWayItEnds() async {
        // Save, Cancel and an interruption all reach the tap as `stop()`, and a recording can end more than one way
        // at once (a Save tap and the Lock Screen's finish in the same moment).
        for stops in 1...3 {
            let session = FakeSession()
            let recorder = Recorder()
            let tap = makeTap(session, recorder)
            let running = await tap.start()
            XCTAssertTrue(running)
            for _ in 0..<stops { await tap.stop() }
            XCTAssertEqual(session.startCount, 1)
            XCTAssertEqual(session.stopCount, 1, "\(stops) stops must end the session once")
            let state = await tap.state
            XCTAssertEqual(state, .stopped)
        }
    }

    func testAStopBeforeTheStartMeansTheTapNeverStarts() async {
        let session = FakeSession()
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        await tap.stop() // Cancel arrived before the recorder's start got as far as the tap
        let running = await tap.start()
        XCTAssertFalse(running)
        XCTAssertEqual(session.startCount, 0, "a late start after the recording ended must not take the microphone")
        XCTAssertEqual(session.stopCount, 0)
    }

    func testAStopWhileTheStartIsWaitingTearsTheSessionDownOnceItIsUp() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let session = FakeSession(startGate: gate)
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        async let running = tap.start()
        while session.startCount == 0 { await Task.yield() } // the start is now waiting on the gate
        await tap.stop()
        release.yield()
        let result = await running
        XCTAssertFalse(result)
        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.stopCount, 1, "the session that came up after Cancel must be let go")
        XCTAssertTrue(recorder.kinds.contains("margin.endPhrase.spike.stoppedBeforeRunning"))
        let state = await tap.state
        XCTAssertEqual(state, .stopped)
    }

    func testASessionThatCannotStartReportsWhyAndIsNotStopped() async {
        let session = FakeSession(startError: LiveInputUnavailable("model_not_installed:supported"))
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        let running = await tap.start()
        XCTAssertFalse(running)
        await tap.stop()
        XCTAssertEqual(session.stopCount, 0, "a start that threw has released what it took; there is nothing to stop")
        XCTAssertEqual(recorder.events.first?.kind, "margin.endPhrase.spike.unavailable")
        XCTAssertEqual(recorder.events.first?.fields["reason"], "model_not_installed:supported")
    }

    func testATapRunsOnlyOnce() async {
        let session = FakeSession()
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        let first = await tap.start()
        let second = await tap.start()
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second start on a running tap must not start a second session")
        await tap.stop()
        let third = await tap.start()
        XCTAssertFalse(third)
        XCTAssertEqual(session.startCount, 1)
    }

    func testWordsReachTheSinkAndTheSummaryCountsThemWithTheCostPerMinute() async {
        let session = FakeSession()
        let recorder = Recorder()
        let wall = ClockBox([1_000, 3_500, 61_000]) // started, first word, stop
        let cpu = ClockBox([200, 18_200])
        let tap = makeTap(session, recorder, wall: { wall.next() }, cpu: { cpu.next() })
        let running = await tap.start()
        XCTAssertTrue(running)
        session.say([word("and", 0, final: false)])
        session.say([word("and", 0), word("that's", 300), word("my", 600)])
        while recorder.words.count < 2 { await Task.yield() }
        await tap.stop()
        XCTAssertEqual(recorder.words.flatMap { $0 }.map(\.text), ["and", "and", "that's", "my"])
        let stopped = recorder.events.last
        XCTAssertEqual(stopped?.kind, "margin.endPhrase.spike.stopped")
        XCTAssertEqual(stopped?.fields["words"], "4")
        XCTAssertEqual(stopped?.fields["finalWords"], "3")
        XCTAssertEqual(stopped?.fields["firstWordAfterMs"], "2500")
        XCTAssertEqual(stopped?.fields["wallMs"], "60000")
        XCTAssertEqual(stopped?.fields["cpuMs"], "18000")
        XCTAssertEqual(stopped?.fields["cpuMsPerMinute"], "18000", "30% of a core is 18 000 ms of CPU per minute")
    }

    func testTheEndPhraseFlagReadsWholeWordsOnly() {
        // The spike logs this flag instead of the words (the export has no redaction for free text).
        let rows: [(spoken: [String], heard: Bool)] = [
            (["stop", "margin"], true),
            (["Stop", "Margin."], true),
            (["STOP MARGIN"], true),
            (["and that's my point,", "end", "margin"], true),
            (["stop,", "margin"], true),
            (["I will not stop margin notes here"], true), // the spike flags what it hears; the rule that ends a Margin is PR 1's
            (["stop", "margins"], false),
            (["stopped", "margin"], false),
            (["end", "margins"], false),
            (["stop", "the", "margin"], false),
            (["margin", "stop"], false),
            (["stop"], false),
            (["margin"], false),
            ([], false),
            ([""], false)
        ]
        for row in rows {
            let words = row.spoken.enumerated().map { LiveInputWord(text: $0.element, startMs: $0.offset * 400, endMs: $0.offset * 400 + 300, isFinal: true) }
            XCTAssertEqual(LiveInputWord.mentionsEndPhrase(words), row.heard, "\(row.spoken)")
        }
    }

    func testThePhraseIsFoundOverTheWholeRunNotJustTheFirstResults() async {
        // A log cap once dropped the one result that mattered: thirty seconds of speech is many finals, and the
        // phrase comes last (the audit of #4296).
        let session = FakeSession()
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        await tap.start()
        for index in 0..<6 { session.say([word("and then I said something number \(index)", index * 5_000)]) }
        session.say([word("and that's my point stop margin", 31_000)])
        while recorder.words.count < 7 { await Task.yield() }
        await tap.stop()
        XCTAssertEqual(recorder.events.last?.fields["heardEndPhrase"], "true")
    }

    func testAPhraseTheRecogniserSplitsAcrossTwoResultsIsStillHeard() async {
        let session = FakeSession()
        let recorder = Recorder()
        let tap = makeTap(session, recorder)
        await tap.start()
        session.say([word("so that is it, stop", 0)])
        session.say([word("margin", 1_400)])
        while recorder.words.count < 2 { await Task.yield() }
        await tap.stop()
        XCTAssertEqual(recorder.events.last?.fields["heardEndPhrase"], "true")
    }

    func testOnlyFinalResultsCountAndALookalikeDoesNot() async {
        for (spoken, final, expected) in [("stop margin", false, "false"), ("stop margins", true, "false"),
                                          ("stopped margin", true, "false"), ("stop margin's", true, "false"),
                                          ("stop margin\u{2019}s", true, "false"), ("end margin", true, "true")] {
            let session = FakeSession()
            let recorder = Recorder()
            let tap = makeTap(session, recorder)
            await tap.start()
            session.say([word(spoken, 0, final: final)])
            while recorder.words.isEmpty { await Task.yield() }
            await tap.stop()
            XCTAssertEqual(recorder.events.last?.fields["heardEndPhrase"], expected, "\(spoken), final: \(final)")
        }
    }

    func testTheSummaryOfANoTimeRunDoesNotDivideByZero() {
        let summary = LiveInputTapSummary(wallMs: 0, cpuMs: 40, wordCount: 0, finalWordCount: 0, firstWordAfterMs: nil)
        XCTAssertEqual(summary.cpuMsPerMinute, 0)
        XCTAssertNil(summary.fields["firstWordAfterMs"])
    }

    func testProcessCpuTimeAdvancesWithWork() {
        let before = LiveInputTap.processCpuMs()
        var total = 0.0
        for index in 0..<30_000_000 { total += Double(index).squareRoot() }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(LiveInputTap.processCpuMs(), before)
    }
}

/// Hands out a fixed list of readings, then repeats the last one.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Int]

    init(_ readings: [Int]) { self.readings = readings }

    func next() -> Int {
        lock.withLock { readings.count > 1 ? readings.removeFirst() : readings[0] }
    }
}
