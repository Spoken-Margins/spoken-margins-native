import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic

/// Supertonic babbles on dense numbers and symbols (#240). A freshly rendered narration chunk that
/// fails `SupertonicOutputCheck` is read by the iOS voice instead, in the same audio format, before
/// it is cached, played or assembled. If the iOS voice can't render it either, the original stays.
/// Each replacement is reported so diagnostics show why the voice changed for that chunk.
final class SupertonicOutputGuard: SupertonicRendering, @unchecked Sendable {
    private let inner: SupertonicRendering
    private let systemVoiceIdentifier: String?
    private let onReplacement: @Sendable (String) -> Void
    private let lock = NSLock()
    private var replacements = 0
    /// iOS-voice files this guard wrote. The renderer deletes only its own output, so the guard
    /// deletes these itself (#311).
    private var replacementURLs: Set<URL> = []

    init(
        wrapping inner: SupertonicRendering,
        systemVoiceIdentifier: String?,
        onReplacement: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.inner = inner
        self.systemVoiceIdentifier = systemVoiceIdentifier
        self.onReplacement = onReplacement
    }

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
        guard let problem = SupertonicOutputCheck.problem(
            text: text, durationSeconds: rendered.duration, speed: Double(speed)
        ) else { return rendered }
        let replacementURL = rendered.audioURL.deletingLastPathComponent()
            .appending(path: "system-voice-\(UUID().uuidString).wav")
        do {
            let duration = try await SystemVoiceChunkRenderer().render(
                text: text,
                voiceIdentifier: systemVoiceIdentifier,
                matching: rendered.audioURL,
                to: replacementURL
            )
            await inner.discardGeneratedAudio(at: rendered.audioURL)
            lock.withLock { _ = replacementURLs.insert(replacementURL) }
            report("system_voice:\(problem)")
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
            report("kept_supertonic:\(problem):system_voice_failed")
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
