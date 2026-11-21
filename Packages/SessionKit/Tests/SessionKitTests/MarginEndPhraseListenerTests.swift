import XCTest
import SessionKit
@testable import SessionKitAudio

/// #3940, PR 3: the listener around one recording. A fake session stands in for the microphone and recogniser (the
/// real one is `SpeechLiveInputSession`, which needs a device); the clock is the test's own, so no test waits on time
/// for the rule. The ticker that confirms a phrase followed by quiet does run on real time, so those waits poll for the
/// signal with a deadline that is only a ceiling.
final class MarginEndPhraseListenerTests: XCTestCase {
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [MarginEndPhraseListener.Signal] = []
        func add(_ signal: MarginEndPhraseListener.Signal) { lock.withLock { stored.append(signal) } }
        var all: [MarginEndPhraseListener.Signal] { lock.withLock { stored } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var now: Int { lock.withLock { value } }
        func set(_ ms: Int) { lock.withLock { value = ms } }
    }

    private final class FakeSession: LiveInputSession, @unchecked Sendable {
        let words: AsyncStream<LiveInputResult>
        private let continuation: AsyncStream<LiveInputResult>.Continuation
        private let lock = NSLock()
        private var stopped = 0
        private let startError: LiveInputUnavailable?
        private let wordsOnStop: [LiveInputWord]

        /// `wordsOnStop` are the last words a recogniser delivers as it is told to stop, before its stream ends.
        init(startError: LiveInputUnavailable? = nil, wordsOnStop: [LiveInputWord] = []) {
            self.wordsOnStop = wordsOnStop
            let (stream, continuation) = AsyncStream<LiveInputResult>.makeStream()
            self.words = stream
            self.continuation = continuation
            self.startError = startError
        }

        var stopCount: Int { lock.withLock { stopped } }
        func start() async throws { if let startError { throw startError } }
        func stop() async {
            lock.withLock { stopped += 1 }
            if !wordsOnStop.isEmpty { say(wordsOnStop) }
            continuation.finish()
        }
        func say(_ batch: [LiveInputWord]) {
            continuation.yield(LiveInputResult(words: batch, startMs: batch.first?.startMs, isFinal: batch.first?.isFinal ?? false))
        }
        /// The recogniser revising what it said for audio from `startMs` on to nothing.
        func retract(from startMs: Int) { continuation.yield(LiveInputResult(words: [], startMs: startMs, isFinal: false)) }
        /// The recogniser finalizing a stretch to nothing.
        func finalizeEmpty(from startMs: Int, to endMs: Int) {
            continuation.yield(LiveInputResult(words: [], startMs: startMs, endMs: endMs, isFinal: true))
        }
        /// The recogniser dying on its own: the stream ends and nobody asked it to.
        func die() { continuation.finish() }
    }

    private func word(_ text: String, _ start: Int, _ end: Int, final: Bool = false) -> LiveInputWord {
        LiveInputWord(text: text, startMs: start, endMs: end, isFinal: final)
    }

    private func make(_ session: FakeSession, _ signals: Signals, _ clock: Clock) -> MarginEndPhraseListener {
        MarginEndPhraseListener(makeSession: { session }, onSignal: signals.add, wallClockMs: { clock.now })
    }

    /// Waits for `condition`, yielding to the listener's tasks. The deadline is a ceiling, not the expected time.
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return XCTFail("never happened: \(message)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testThePhraseThenQuietEndsTheMarginOnceAfterTheConfirmingSecond() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        XCTAssertEqual(signals.all, [.hint(.listening)])
        // "that is my point stop margin": "stop margin" ends at 7,300.
        clock.set(8_400)
        session.say([word("that", 5_000, 5_300), word("is", 5_400, 5_600), word("my", 5_700, 6_000), word("point", 6_100, 6_500),
                     word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)])
        await eventually("finishing hint") { signals.all.contains(.hint(.finishing)) }
        XCTAssertFalse(signals.all.contains(.end), "not before a second of quiet and the delivery lag")
        clock.set(9_300)
        await eventually("end") { signals.all.contains(.end) }
        clock.set(60_000)
        try? await Task.sleep(for: .milliseconds(400)) // a few ticks: the end is not repeated
        XCTAssertEqual(signals.all.filter { $0 == .end }.count, 1)
        await listener.stop()
        XCTAssertEqual(session.stopCount, 1)
    }

    func testQuietAloneNeverEnds() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        clock.set(10_000)
        session.say([word("hello", 2_000, 2_300, final: true)])
        clock.set(10 * 60_000)
        // Several ticks of ten quiet minutes. The rule itself is tested without any wait in NoQuietEndTests; this checks
        // that the ticker adds no timer of its own.
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(signals.all, [.hint(.listening)])
        await listener.stop()
    }

    func testAGuessTheRecogniserTakesBackNeverEnds() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        // A volatile "stop margin" (6,600 to 7,300) shows the hint; the recogniser then revises that stretch to nothing.
        clock.set(8_400)
        session.say([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)])
        await eventually("finishing hint") { signals.all.contains(.hint(.finishing)) }
        session.retract(from: 6_600)
        await eventually("hint back to listening") { signals.all.last == .hint(.listening) }
        clock.set(60_000)
        try? await Task.sleep(for: .milliseconds(400)) // a few ticks
        XCTAssertFalse(signals.all.contains(.end), "a withdrawn phrase is not confirmed")
        await listener.stop()
    }

    func testAGuessFinalizedToNothingNeverEnds() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        clock.set(8_400)
        session.say([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)])
        await eventually("finishing hint") { signals.all.contains(.hint(.finishing)) }
        session.finalizeEmpty(from: 6_600, to: 7_300)
        await eventually("hint back to listening") { signals.all.last == .hint(.listening) }
        clock.set(60_000)
        try? await Task.sleep(for: .milliseconds(400)) // a few ticks
        XCTAssertFalse(signals.all.contains(.end))
        await listener.stop()
    }

    func testASessionThatCannotStartSaysWhyAndIsNeverListening() async {
        let session = FakeSession(startError: LiveInputUnavailable("model_not_installed:supported"))
        let signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        XCTAssertEqual(signals.all, [.couldNotStart(reason: "model_not_installed:supported")])
        await listener.stop()
        XCTAssertEqual(session.stopCount, 0)
    }

    func testTheRecogniserStoppingMidMarginEndsOnlyTheListening() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        session.die()
        await eventually("stopped mid-Margin") { signals.all.contains(.stoppedMidMargin) }
        XCTAssertEqual(signals.all, [.hint(.listening), .hint(.none), .stoppedMidMargin], "no end: the recording goes on")
        clock.set(60_000)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(signals.all.contains(.end))
        await listener.stop()
        await listener.stop()
        XCTAssertEqual(session.stopCount, 1, "stop after a death still lets the session go, once")
    }

    func testAStopBeforeTheStartMeansItNeverListens() async {
        let session = FakeSession(), signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.stop() // Cancel arrived first
        await listener.start()
        XCTAssertEqual(signals.all, [])
        XCTAssertEqual(session.stopCount, 0)
    }

    func testWordsAfterAStopAreIgnored() async {
        // Stopping a recogniser delivers its last words first: "stop margin" lands while the listener is being stopped.
        let session = FakeSession(wordsOnStop: [word("stop", 6_600, 6_900, final: true), word("margin", 7_000, 7_300, final: true)])
        let signals = Signals(), clock = Clock()
        let listener = make(session, signals, clock)
        await listener.start()
        clock.set(20_000)
        await listener.stop()
        try? await Task.sleep(for: .milliseconds(300)) // a few ticks: a stopped listener never ends anything
        XCTAssertEqual(signals.all, [.hint(.listening)])
    }
}
