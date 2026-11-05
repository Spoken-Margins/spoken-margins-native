import Foundation
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
        guard isAvailable, !text.isEmpty else { return nil }
        var label: ListeningMapSummaryValidator.SceneLabel?
        for _ in 0..<Self.attempts where label == nil {
            if let candidate = try? await client.labelListeningMapChapter(text: text, chapterNumber: chapterNumber) {
                label = try? ListeningMapSummaryValidator.validate(candidate, sourceText: text)
            }
        }
        return label
    }
}
