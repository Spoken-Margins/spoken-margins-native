import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A word the live recogniser heard while a Margin records, with its time in the recogniser's own audio clock (zero
/// is the first buffer the tap fed it).
public struct LiveInputWord: Sendable, Equatable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var isFinal: Bool

    public init(text: String, startMs: Int, endMs: Int, isFinal: Bool) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.isFinal = isFinal
    }
}

/// One result from the recogniser: its words (none when a guess was revised to nothing), where the result starts in
/// the recogniser's audio clock, and whether it is final. The start is what lets a later result take back an earlier
/// guess for the same stretch of audio, so a "stop margin" the recogniser withdrew can't be confirmed (#3940).
public struct LiveInputResult: Sendable, Equatable {
    public var words: [LiveInputWord]
    public var startMs: Int?
    public var isFinal: Bool

    public init(words: [LiveInputWord], startMs: Int? = nil, isFinal: Bool = false) {
        self.words = words
        self.startMs = startMs
        self.isFinal = isFinal
    }
}

extension LiveInputWord {
    /// The words as lowercase tokens: letters, digits and apostrophes (a curly one counts as a straight one, so
    /// "margin's" reads the same however the recogniser wrote it). Everything else separates tokens.
    public static func tokens(_ words: [LiveInputWord]) -> [String] {
        words.map(\.text).joined(separator: " ").lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    /// Whether `tokens` hold "stop margin" or "end margin" as two whole words in a row.
    public static func tokensHoldEndPhrase(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        for index in 0..<(tokens.count - 1) where tokens[index + 1] == "margin" {
            if tokens[index] == "stop" || tokens[index] == "end" { return true }
        }
        return false
    }

    /// Whether these words say "stop margin" or "end margin" as two whole words in a row, for the spike's one-flag
    /// evidence that the phrase was heard. Case, punctuation and spacing don't matter; "stop margins", "stopped
    /// margin" and the two words apart do. The words themselves never go to Diagnostics (the export has no redaction
    /// for free text), so the answer is all that is kept.
    public static func mentionsEndPhrase(_ words: [LiveInputWord]) -> Bool {
        tokensHoldEndPhrase(tokens(words))
    }
}

/// Why a live-input session could not start. `reason` is a short stable key for Diagnostics, never listener words.
public struct LiveInputUnavailable: Error, Sendable, Equatable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// One live look at the microphone: an audio-engine input tap feeding a recogniser (#3940, PR 0 of the Design).
/// The real one is `SpeechLiveInputSession`; tests use a fake so the lifecycle is checked on the host.
///
/// Contract: `start()` either returns with the tap running, or throws having already released everything it took, so
/// `stop()` is called only after a `start()` that returned. `stop()` is safe to call once and must leave nothing
/// running. `words` is the one stream of what was heard; it finishes when the session stops.
public protocol LiveInputSession: Sendable {
    var words: AsyncStream<LiveInputResult> { get }
    func start() async throws
    func stop() async
}

/// What the spike reports about one run, for Diagnostics. Plain numbers and keys: the words themselves go out as
/// their own events.
public struct LiveInputTapSummary: Sendable, Equatable {
    public var wallMs: Int
    public var cpuMs: Int
    public var wordCount: Int
    public var finalWordCount: Int
    public var firstWordAfterMs: Int?
    /// Whether the final results, across the whole run, said "stop margin" or "end margin". Kept for the run, not
    /// per event, so a log cap can't drop the one result that matters (#3940).
    public var heardEndPhrase = false

    /// Process CPU time per minute of tap time, for the Design's cost note ("CPU above 30% of a core sustained").
    public init(wallMs: Int, cpuMs: Int, wordCount: Int, finalWordCount: Int, firstWordAfterMs: Int?, heardEndPhrase: Bool = false) {
        self.wallMs = wallMs
        self.cpuMs = cpuMs
        self.wordCount = wordCount
        self.finalWordCount = finalWordCount
        self.firstWordAfterMs = firstWordAfterMs
        self.heardEndPhrase = heardEndPhrase
    }

    public var cpuMsPerMinute: Int {
        guard wallMs > 0 else { return 0 }
        return Int((Double(cpuMs) / Double(wallMs) * 60_000).rounded())
    }

    public var fields: [String: String] {
        var result = [
            "wallMs": String(wallMs), "cpuMs": String(cpuMs), "cpuMsPerMinute": String(cpuMsPerMinute),
            "words": String(wordCount), "finalWords": String(finalWordCount), "heardEndPhrase": String(heardEndPhrase)
        ]
        if let firstWordAfterMs { result["firstWordAfterMs"] = String(firstWordAfterMs) }
        return result
    }
}

/// Runs one `LiveInputSession` for the length of one recording. Single use: a tap that has stopped (or was stopped
/// before it started) never starts again, so a late `start()` after Cancel or Save cannot leave a microphone tap
/// running with no recording to match. Every start that returned true is matched by exactly one session `stop()`,
/// whichever of cancel, save or an interruption comes first, and even when it comes while the start is still waiting.
public actor LiveInputTap {
    public enum State: Sendable, Equatable {
        case idle, starting, running, stopped
    }

    public typealias Event = @Sendable (_ kind: String, _ fields: [String: String]) -> Void

    private let makeSession: @Sendable () -> any LiveInputSession
    private let onWords: @Sendable ([LiveInputWord]) -> Void
    private let onResult: @Sendable (LiveInputResult) -> Void
    private let onEvent: Event
    private let onStreamEnded: @Sendable () -> Void
    private let wallClockMs: @Sendable () -> Int
    private let cpuClockMs: @Sendable () -> Int

    public private(set) var state: State = .idle
    private var session: (any LiveInputSession)?
    private var consumer: Task<Void, Never>?
    private var stopRequestedWhileStarting = false

    private var startedWallMs = 0
    private var startedCpuMs = 0
    private var wordCount = 0
    private var finalWordCount = 0
    private var firstWordAfterMs: Int?
    private var heardEndPhrase = false
    /// The last token of the final results so far, so a phrase the recogniser splits across two results is found.
    private var lastFinalToken: String?

    public init(
        makeSession: @escaping @Sendable () -> any LiveInputSession,
        onWords: @escaping @Sendable ([LiveInputWord]) -> Void = { _ in },
        onResult: @escaping @Sendable (LiveInputResult) -> Void = { _ in },
        onEvent: @escaping Event,
        onStreamEnded: @escaping @Sendable () -> Void = {},
        wallClockMs: @escaping @Sendable () -> Int = { LiveInputTap.monotonicMs() },
        cpuClockMs: @escaping @Sendable () -> Int = { LiveInputTap.processCpuMs() }
    ) {
        self.makeSession = makeSession
        self.onWords = onWords
        self.onResult = onResult
        self.onEvent = onEvent
        self.onStreamEnded = onStreamEnded
        self.wallClockMs = wallClockMs
        self.cpuClockMs = cpuClockMs
    }

    /// True when the tap is running. False when it could not start (the reason goes to `onEvent`), or when a stop
    /// arrived first, in which case everything it took has been let go again.
    @discardableResult
    public func start() async -> Bool {
        guard state == .idle else { return false }
        state = .starting
        let session = makeSession()
        do {
            try await session.start()
        } catch {
            state = .stopped
            let reason = (error as? LiveInputUnavailable)?.reason ?? "start_failed:\(type(of: error))"
            onEvent("margin.endPhrase.spike.unavailable", ["reason": reason])
            return false
        }
        if stopRequestedWhileStarting {
            // Cancel or Save came while the start waited: the recording is over, so the tap goes straight back.
            await session.stop()
            state = .stopped
            onEvent("margin.endPhrase.spike.stoppedBeforeRunning", [:])
            return false
        }
        self.session = session
        state = .running
        startedWallMs = wallClockMs()
        startedCpuMs = cpuClockMs()
        let words = session.words
        let onWords = self.onWords
        let onResult = self.onResult
        consumer = Task { [weak self] in
            for await result in words {
                guard !Task.isCancelled else { break }
                await self?.heard(result.words)
                if !result.words.isEmpty { onWords(result.words) }
                onResult(result)
            }
            await self?.sessionWordsEnded()
        }
        onEvent("margin.endPhrase.spike.started", [:])
        return true
    }

    /// Ends the tap. Safe to call at any time, any number of times: before the start, while it waits, while it runs
    /// and after it ended.
    public func stop() async {
        switch state {
        case .idle:
            state = .stopped
        case .starting:
            stopRequestedWhileStarting = true
        case .running:
            state = .stopped
            let finishing = session
            session = nil
            let summaryClockWall = wallClockMs()
            let summaryClockCpu = cpuClockMs()
            await finishing?.stop() // finishing the recogniser delivers the last words before the stream ends
            await consumer?.value
            consumer = nil
            let summary = LiveInputTapSummary(
                wallMs: max(0, summaryClockWall - startedWallMs),
                cpuMs: max(0, summaryClockCpu - startedCpuMs),
                wordCount: wordCount,
                finalWordCount: finalWordCount,
                firstWordAfterMs: firstWordAfterMs,
                heardEndPhrase: heardEndPhrase
            )
            onEvent("margin.endPhrase.spike.stopped", summary.fields)
        case .stopped:
            break
        }
    }

    /// The session's words ended while the tap was still running: the recogniser stopped on its own (an error, or the
    /// system took it). A stop the tap itself asked for sets `.stopped` first, so it never lands here.
    private func sessionWordsEnded() {
        guard state == .running else { return }
        onEvent("margin.endPhrase.spike.streamEnded", [:])
        onStreamEnded()
    }

    private func heard(_ batch: [LiveInputWord]) {
        guard !batch.isEmpty else { return }
        if firstWordAfterMs == nil { firstWordAfterMs = max(0, wallClockMs() - startedWallMs) }
        wordCount += batch.count
        let finals = batch.filter(\.isFinal)
        finalWordCount += finals.count
        if !finals.isEmpty {
            // The whole run, not one event: a result that ends in "stop" followed by one that starts with "margin" counts.
            var tokens = LiveInputWord.tokens(finals)
            if let lastFinalToken { tokens.insert(lastFinalToken, at: 0) }
            if LiveInputWord.tokensHoldEndPhrase(tokens) { heardEndPhrase = true }
            lastFinalToken = tokens.last
        }
    }

    public static func monotonicMs() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// CPU time this process has used so far, user plus system, in milliseconds.
    public static func processCpuMs() -> Int {
        var usage = rusage()
        #if canImport(Darwin)
        let who = RUSAGE_SELF
        #else
        let who = Int32(RUSAGE_SELF.rawValue) // Glibc types the constant as an enum, the call wants its raw Int32
        #endif
        guard getrusage(who, &usage) == 0 else { return 0 }
        let user = Int(usage.ru_utime.tv_sec) * 1000 + Int(usage.ru_utime.tv_usec) / 1000
        let system = Int(usage.ru_stime.tv_sec) * 1000 + Int(usage.ru_stime.tv_usec) / 1000
        return user + system
    }
}
