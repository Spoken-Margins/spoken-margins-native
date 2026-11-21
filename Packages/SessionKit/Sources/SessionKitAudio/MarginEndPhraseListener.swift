import Foundation
import SessionKit

/// Listens for the spoken end phrase while one Margin records (#3940, PR 3 of the Design). It runs a `LiveInputTap`
/// (the audio-engine tap beside the recorder), feeds what the recogniser hears to `MarginEndPhraseDecider`, and tells
/// its owner when to end the Margin and what the recording screen should say.
///
/// Single use, like the tap: one listener per recording. It never ends a Margin itself; it signals `.end` and the
/// owner finishes the recording the way a tap on Save does. It never asks for permission and never touches the
/// recorder. Anything that goes wrong while listening ends the *listening*, never the recording.
public final class MarginEndPhraseListener: @unchecked Sendable {
    public enum Signal: Sendable, Equatable {
        /// What the screen's hint line should be.
        case hint(MarginEndPhraseHint)
        /// The phrase was heard and confirmed: end and save.
        case end
        /// Listening could not start. `reason` is a short stable key (`LiveInputUnavailable`).
        case couldNotStart(reason: String)
        /// The recogniser stopped on its own mid-Margin. The recording goes on untouched.
        case stoppedMidMargin
    }

    public typealias SignalHandler = @Sendable (Signal) -> Void

    /// How often time is checked when no result arrives, so a phrase followed by quiet is still confirmed.
    public static let tickIntervalMs = 150

    private let makeSession: @Sendable () -> any LiveInputSession
    private let onSignal: SignalHandler
    private let onEvent: LiveInputTap.Event
    private let wallClockMs: @Sendable () -> Int

    private let lock = NSLock()
    private var decider = MarginEndPhraseDecider()
    private var tap: LiveInputTap?
    private var ticker: Task<Void, Never>?
    private var startedAtMs: Int?
    private var stopped = false

    public init(
        makeSession: @escaping @Sendable () -> any LiveInputSession,
        onSignal: @escaping SignalHandler,
        onEvent: @escaping LiveInputTap.Event = { _, _ in },
        wallClockMs: @escaping @Sendable () -> Int = { LiveInputTap.monotonicMs() }
    ) {
        self.makeSession = makeSession
        self.onSignal = onSignal
        self.onEvent = onEvent
        self.wallClockMs = wallClockMs
    }

    /// Starts listening. Returns once it is listening or has said why it can't.
    public func start() async {
        let tap = LiveInputTap(
            makeSession: makeSession,
            onWords: { [weak self] batch in self?.heard(batch) },
            onEvent: { [weak self] kind, fields in self?.tapEvent(kind, fields) },
            onStreamEnded: { [weak self] in self?.recogniserStopped() }
        )
        let alreadyStopped = lock.withLock { () -> Bool in
            if stopped { return true }
            self.tap = tap
            return false
        }
        guard !alreadyStopped else { return }
        let started = await tap.start()
        guard started else { return } // the tap's `unavailable` event has said why
        // Audio time zero is the first buffer after the start, so the clock starts when the start returns: a clock
        // started earlier would run ahead of the results and confirm a phrase too soon.
        let begin = wallClockMs()
        let listening = lock.withLock { () -> Bool in
            if stopped { return false }
            startedAtMs = begin
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(Self.tickIntervalMs))
                    guard !Task.isCancelled else { return }
                    self?.tick()
                }
            }
            return true
        }
        if listening { onSignal(.hint(.listening)) }
    }

    /// Ends listening. Safe at any time and any number of times: before the start, while it waits, while it listens,
    /// and after it ended.
    public func stop() async {
        let (tap, ticker) = lock.withLock { () -> (LiveInputTap?, Task<Void, Never>?) in
            stopped = true
            defer { self.tap = nil; self.ticker = nil }
            return (self.tap, self.ticker)
        }
        ticker?.cancel()
        await tap?.stop()
    }

    // MARK: Results

    private func heard(_ batch: [LiveInputWord]) {
        let words = batch.map { MarginEndPhraseWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) }
        let isFinal = batch.first?.isFinal ?? false
        let step = lock.withLock { () -> MarginEndPhraseDecider.Step in
            guard !stopped else { return .unchanged }
            return decider.receive(words, isFinal: isFinal, sinceStartMs: sinceStartMs())
        }
        emit(step)
    }

    private func tick() {
        let step = lock.withLock { () -> MarginEndPhraseDecider.Step in
            guard !stopped, startedAtMs != nil else { return .unchanged }
            return decider.tick(sinceStartMs: sinceStartMs())
        }
        emit(step)
    }

    /// Time since the recogniser started; 0 for a result that lands before the start has returned, which can only
    /// make the rule wait longer. Call with the lock held.
    private func sinceStartMs() -> Int {
        guard let startedAtMs else { return 0 }
        return max(0, wallClockMs() - startedAtMs)
    }

    private func emit(_ step: MarginEndPhraseDecider.Step) {
        switch step {
        case .unchanged: break
        case .listening: onSignal(.hint(.listening))
        case .finishing: onSignal(.hint(.finishing))
        case .end: onSignal(.end)
        }
    }

    private func tapEvent(_ kind: String, _ fields: [String: String]) {
        onEvent(kind, fields)
        if kind.hasSuffix(".unavailable") {
            onSignal(.couldNotStart(reason: fields["reason"] ?? "unknown"))
        }
    }

    private func recogniserStopped() {
        let wasListening = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true // nothing more is heard; the recording goes on
            ticker?.cancel()
            ticker = nil
            return true
        }
        guard wasListening else { return }
        onSignal(.hint(.none))
        onSignal(.stoppedMidMargin)
    }
}
