import Foundation
import SessionKit
import SessionKitPersistence

/// The Supertonic player's prepared-audio hooks, all on the text prepared audio is planned from
/// (#336): a new-reader PDF's listenable text, `Item.text` for everything else. The plan, its
/// identity, each commit and each lookup must use that same text, or the player matches nothing.
struct PreparedSpeechHooks: Sendable {
    static let texts = PreparedSpeechTextCache()

    let store: SQLiteSessionStore
    let coordinator: PreparedAudioCoordinator
    let signatureTask: Task<TTSRenderSignature, Error>

    /// What background preparation, the player and assembly plan the item's prepared audio from.
    static func preparedText(of item: Item, in store: SQLiteSessionStore?) -> String? {
        texts.resolve(item: item, documents: store)?.text
    }

    func articleText(itemId: String) -> String? {
        (try? store.loadItem(id: itemId)).flatMap { Self.preparedText(of: $0, in: store) }
    }

    /// The item's prepared text, while the player's article plan is still for it. A turn is not
    /// a Library item, and a changed article matches nothing (#312).
    private func sourceText(itemId: String, articleIdentity: String) -> String? {
        guard let text = articleText(itemId: itemId),
              NarrationChunkPlanner.identity(ofArticle: text) == articleIdentity else { return nil }
        return text
    }

    func planned(itemId: String, articleIdentity: String, plan: [PreparedChunkPlan]) async {
        guard let signature = try? await signatureTask.value,
              let sourceText = sourceText(itemId: itemId, articleIdentity: articleIdentity) else { return }
        _ = try? await coordinator.begin(itemId: itemId, sourceText: sourceText, signature: signature, plan: plan, schedulesJob: false)
    }

    func rendered(itemId: String, articleIdentity: String, plan: PreparedChunkPlan, audioURL: URL, durationMs: Int, engine: String) async {
        guard let signature = try? await signatureTask.value,
              let sourceText = sourceText(itemId: itemId, articleIdentity: articleIdentity) else { return }
        try? await coordinator.commit(itemId: itemId, signature: signature, plan: plan, sourceText: sourceText, audioURL: audioURL, durationMs: durationMs, engine: engine)
    }

    /// `engine` nil: the voice's own saved audio. Another engine: that engine's saved stand-in (#1680).
    func lookup(itemId: String, articleIdentity: String, plan: PreparedChunkPlan, engine: String? = nil) async -> PreparedChunkLookupResult? {
        guard let signature = try? await signatureTask.value,
              let sourceText = sourceText(itemId: itemId, articleIdentity: articleIdentity) else { return nil }
        return try? await coordinator.committedChunk(itemId: itemId, signature: signature, plan: plan, sourceText: sourceText, engine: engine)
    }
}
