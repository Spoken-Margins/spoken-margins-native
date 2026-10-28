import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic

/// Supertonic babbles on dense numbers and symbols (#240). A freshly rendered narration chunk that
/// fails `SupertonicOutputCheck` is read by the iOS voice instead, in the same audio format, before
/// it is cached, played or assembled. If the iOS voice can't render it either, the original stays.
/// Each replacement is reported so diagnostics show why the voice changed for that chunk, and how long the iOS
/// voice's write took, written or not (#1695).
final class SupertonicOutputGuard: SupertonicRendering, @unchecked Sendable {
    /// Reads `text` with the iOS voice into `output`, in `reference`'s format, and returns its
    /// duration in seconds.
    typealias StandInRender = @Sendable (_ text: String, _ voiceIdentifier: String?, _ reference: URL, _ output: URL) async throws -> TimeInterval

    static let systemVoiceStandIn: StandInRender = { text, voiceIdentifier, reference, output in
        try await SystemVoiceChunkRenderer().render(text: text, voiceIdentifier: voiceIdentifier, matching: reference, to: output)
    }

    private let inner: SupertonicRendering
    private let systemVoiceIdentifier: String?
    private let onReplacement: @Sendable (String) -> Void
    private let standIn: StandInRender
    private let writeLog: StandInWriteLog
    /// Seconds on a clock that only moves forward (it stops while the device sleeps, so a write across sleep reads
    /// short; fine for a measurement). Tests replace it.
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var replacements = 0
    /// iOS-voice files this guard wrote. The renderer deletes only its own output, so the guard
    /// deletes these itself (#311).
    private var replacementURLs: Set<URL> = []

    init(
        wrapping inner: SupertonicRendering,
        systemVoiceIdentifier: String?,
        onReplacement: @escaping @Sendable (String) -> Void = { _ in },
        standIn: @escaping StandInRender = SupertonicOutputGuard.systemVoiceStandIn,
        writeLog: StandInWriteLog = .shared,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.inner = inner
        self.systemVoiceIdentifier = systemVoiceIdentifier
        self.onReplacement = onReplacement
        self.standIn = standIn
        self.writeLog = writeLog
        self.now = now
    }

    /// The wrapped renderer's engine, so a downloaded voice's own chunks still count as its own (#2700).
    var engine: String { inner.engine }
    var isLoadingModel: Bool { inner.isLoadingModel }
    func prepareToRender() async { await inner.prepareToRender() }
    func setEventSink(_ sink: @escaping @Sendable (String, [String: String]) -> Void) { inner.setEventSink(sink) }

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        let rendered = try await inner.render(
            text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps
        )
        // The check's limits are Supertonic's (#240); another engine's pacing would trip them falsely.
        guard rendered.engine == SupertonicNarrationResult.supertonicEngine else { return rendered }
        guard let problem = SupertonicOutputCheck.problem(
            text: text, durationSeconds: rendered.modelDuration, speed: Double(speed)
        ) else { return rendered }
        // A render nobody waits for any more (a timeout handed the text to the live iOS voice, or a
        // stop) must not start another speech synthesizer: writing one while the iOS voice speaks
        // is the likely reason that voice went silent while it said it was playing (#288).
        if Task.isCancelled {
            await inner.discardGeneratedAudio(at: rendered.audioURL)
            throw CancellationError()
        }
        let replacementURL = rendered.audioURL.deletingLastPathComponent()
            .appending(path: "system-voice-\(UUID().uuidString).wav")
        let writeNumber = writeLog.writeStarted()
        let startedAt = now()
        func timing() -> String { StandInWriteLog.describe(writeNumber: writeNumber, elapsed: now() - startedAt) }
        do {
            let duration = try await standIn(text, systemVoiceIdentifier, rendered.audioURL, replacementURL)
            let wrote = timing()
            await inner.discardGeneratedAudio(at: rendered.audioURL)
            lock.withLock { _ = replacementURLs.insert(replacementURL) }
            report("system_voice:\(problem); \(wrote)")
            return SupertonicNarrationResult(
                audioURL: replacementURL,
                duration: duration,
                sampleRate: rendered.sampleRate,
                renderDuration: rendered.renderDuration,
                sessionLoadCount: rendered.sessionLoadCount,
                engine: SupertonicNarrationResult.systemVoiceEngine
            )
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            report("kept_supertonic:\(problem):system_voice_failed; \(timing())")
            return rendered
        }
    }

    /// Renders, hands the result to `keep` (which copies what it needs), then discards the render
    /// on every path. Background preparation made a guard per chunk and never discarded, so each
    /// flagged chunk left its iOS-voice file behind (#363 audit).
    /// Runs on the caller's actor, so `keep` can use the caller's state.
    func render<Kept>(
        text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int,
        isolation: isolated (any Actor)? = #isolation,
        keep: (SupertonicNarrationResult) async throws -> Kept
    ) async throws -> Kept {
        let rendered = try await render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
        do {
            let kept = try await keep(rendered)
            await discardGeneratedAudio(at: rendered.audioURL)
            return kept
        } catch {
            await discardGeneratedAudio(at: rendered.audioURL)
            throw error
        }
    }

    func discardGeneratedAudio(at url: URL) async {
        if lock.withLock({ replacementURLs.remove(url) }) != nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        await inner.discardGeneratedAudio(at: url)
    }

    private func report(_ outcome: String) {
        let count = lock.withLock { () -> Int in
            replacements += 1
            return replacements
        }
        onReplacement("\(count) flagged; last \(outcome)")
    }
}
