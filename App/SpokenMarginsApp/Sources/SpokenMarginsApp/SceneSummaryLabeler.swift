import Foundation
import FoundationModels
import SessionKit

/// The one step that turns a scene's text into a checked title and summary with the on-device model (#3450). A
/// podcast's scenes (`EpisodeMapPreparer`) and an article's or PDF's (`TextSceneMapPreparer`) both call it, so they
/// share the prompt, the two tries and the grounding check (`ListeningMapSummaryValidator`), and Skim speaks both the
/// same way.
struct SceneSummaryLabeler {
    /// The model is asked at most this many times for one scene before the scene goes without a summary.
    static let attempts = 2

    let client: any LocalFoundationModelClient

    var isAvailable: Bool { client.availability().isAvailable }

    /// The checked label, or nil when the model is unavailable, `text` is empty, or no try passed the check.
    func label(text: String, chapterNumber: Int) async -> ListeningMapSummaryValidator.SceneLabel? {
        if case .label(let label) = await answer(text: text, chapterNumber: chapterNumber) { return label }
        return nil
    }

    /// Like `label`, but says why there is none: the model answered and no try passed the check (`.rejected`: asking
    /// again returns the same answer, so the scene is settled), or every call threw (`.modelFailed`: the model was
    /// busy or not ready, so the scene is still waiting) (#3461).
    func answer(text: String, chapterNumber: Int) async -> TextSceneSummaryRun.SceneAnswer {
        guard isAvailable, !text.isEmpty else { return .modelFailed }
        var answered = false
        for _ in 0..<Self.attempts {
            let candidate: LocalListeningMapLabel
            do {
                candidate = try await client.labelListeningMapChapter(text: text, chapterNumber: chapterNumber)
            } catch {
                // The model decodes greedily, so an error this text always causes comes back on the next try too: it is
                // the model's verdict on the scene, not a fault of the moment (#3461).
                if Self.repeatsForTheSameText(error) { return .rejected }
                continue
            }
            answered = true
            if let label = try? ListeningMapSummaryValidator.validate(candidate, sourceText: text) { return .label(label) }
        }
        return answered ? .rejected : .modelFailed
    }

    /// True for an error the same text will cause every time: the model refused it (guardrails), answered with
    /// something that can't be read as a label, or the text doesn't fit. Anything else (busy, not ready, rate limited,
    /// cancelled, and any error not known here) is a fault of the moment, so the scene stays waiting.
    static func repeatsForTheSameText(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is DecodingError { return true }
        if let modelError = error as? LocalFoundationModelError {
            switch modelError {
            case .emptyResponse, .invalidStructuredResponse, .outputTooLong, .excessiveSourceQuotation: return true
            case .unavailable, .sourceTextUnavailable, .invalidInterjectionSummary: return false
            }
        }
        if AppleFoundationModelClient.isSafetyRejection(error) { return true }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize, .decodingFailure, .unsupportedLanguageOrLocale: return true
            default: return false
            }
        }
        return false
    }
}
