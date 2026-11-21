#if canImport(AVFoundation) && canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// The real `LiveInputSession` (#3940, PR 0 of the Design): an `AVAudioEngine` input tap with no output, run beside
/// the Margin's `AVAudioRecorder`, feeding the on-device `SpeechTranscriber` through a `SpeechAnalyzer`.
///
/// It never asks for anything: Speech Recognition permission and the on-device model are checked, and when either
/// is missing the session reports why and does not start (a prompt with the microphone live is the #2966 trap). It
/// never touches the recorder, the audio session's category or its activation: the Margin's recorder owns those.
@available(iOS 26.0, macOS 26.0, *)
public final class SpeechLiveInputSession: LiveInputSession, @unchecked Sendable {
    public let words: AsyncStream<LiveInputResult>
    private let wordsContinuation: AsyncStream<LiveInputResult>.Continuation
    private let isAuthorized: @Sendable () -> Bool

    // Touched only by `start()` and `stop()`, which `LiveInputTap` calls one at a time.
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []

    /// `isAuthorized`: whether Speech Recognition is already allowed, with no question to ask.
    public init(isAuthorized: @escaping @Sendable () -> Bool) {
        let (stream, continuation) = AsyncStream<LiveInputResult>.makeStream()
        self.words = stream
        self.wordsContinuation = continuation
        self.isAuthorized = isAuthorized
    }

    public func start() async throws {
        do {
            try await begin()
        } catch {
            await release(finishing: false)
            throw error
        }
    }

    public func stop() async {
        await release(finishing: true)
    }

    private func begin() async throws {
        guard isAuthorized() else { throw LiveInputUnavailable("speech_not_authorized") }
        guard SpeechTranscriber.isAvailable else { throw LiveInputUnavailable("transcriber_unavailable") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw LiveInputUnavailable("locale_unsupported")
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else { throw LiveInputUnavailable("model_not_installed:\(status)") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveInputUnavailable("no_analyzer_format")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (inputs, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        let continuation = wordsContinuation
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    // An empty result is kept: the recogniser revising a guess to nothing must reach the rule.
                    continuation.yield(LiveInputResult(
                        words: Self.heardWords(in: result),
                        startMs: Self.milliseconds(result.range.start),
                        isFinal: result.isFinal
                    ))
                }
            } catch {
                // The stream ending with an error is the recogniser stopping; the tap reports what it heard.
            }
            continuation.finish()
        }
        try await analyzer.start(inputSequence: inputs)

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LiveInputUnavailable("input_format_empty")
        }
        guard let converter = LiveInputBufferConverter(from: inputFormat, to: format) else {
            throw LiveInputUnavailable("converter_unavailable")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converted = converter.convert(buffer) { builder.yield(AnalyzerInput(buffer: converted)) }
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw LiveInputUnavailable("engine_start_failed:\((error as NSError).domain)/\((error as NSError).code)")
        }
        watchForTheEngineStopping(engine, builder: builder)
    }

    /// A route change that alters the microphone's format stops an engine by itself, and an interruption takes the
    /// microphone away. Neither ends the recogniser's results, so without this the listener would think it still
    /// listens. Finishing the streams makes the tap report that the recogniser stopped mid-Margin: the hint goes away,
    /// the recording goes on and the could-not-listen sound plays once.
    private func watchForTheEngineStopping(_ engine: AVAudioEngine, builder: AsyncStream<AnalyzerInput>.Continuation) {
        let continuation = wordsContinuation
        let stopped: @Sendable (Notification) -> Void = { _ in
            builder.finish()
            continuation.finish()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: stopped
        ))
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue { stopped(note) }
        })
        #endif
    }

    /// Lets go of everything, in the order that stops new audio first. With `finishing`, the recogniser is given a
    /// moment to deliver the words it already holds, so the last sentence is not lost.
    private func release(finishing: Bool) async {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            self.analyzer = nil
            if finishing {
                await Self.finalize(analyzer, within: 3)
            }
            await analyzer.cancelAndFinishNow()
        }
        if let resultsTask {
            self.resultsTask = nil
            if !finishing { resultsTask.cancel() }
            await resultsTask.value
        }
        wordsContinuation.finish()
    }

    /// Waits for the analyzer to deliver what it holds, but never longer than `seconds`: a task group would wait for a
    /// finalize that ignores cancellation, so the two are raced with plain tasks and the first to finish wins.
    private static func finalize(_ analyzer: SpeechAnalyzer, within seconds: Int) async {
        let (done, signal) = AsyncStream<Void>.makeStream()
        let work = Task {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            signal.yield()
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            signal.yield()
        }
        for await _ in done { break }
        work.cancel()
        timer.cancel()
    }

    private static func milliseconds(_ time: CMTime) -> Int? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return nil }
        return max(0, Int((seconds * 1000).rounded()))
    }

    private static func heardWords(in result: SpeechTranscriber.Result) -> [LiveInputWord] {
        result.text.runs.compactMap { run -> LiveInputWord? in
            let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let range = run.audioTimeRange else { return nil }
            let startMs = max(0, Int((CMTimeGetSeconds(range.start) * 1000).rounded()))
            let durationMs = max(1, Int((CMTimeGetSeconds(range.duration) * 1000).rounded()))
            return LiveInputWord(text: text, startMs: startMs, endMs: startMs + durationMs, isFinal: result.isFinal)
        }
    }
}

/// Converts the microphone's buffers to the format the analyzer asked for. Used from the one audio thread of the tap.
private final class LiveInputBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        outputFormat = output
        if input == output {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: input, to: output) else { return nil }
            converter = made
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
#endif
