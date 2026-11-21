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

    /// Whether a preparation created now for this item is planned with note chunks (#3777). The player asks it when it
    /// starts the item, and every other place that creates a preparation asks the same rule with the same inputs
    /// (`FootnotePlanDecision`), so they agree. Everything after creation follows the manifest's own kind.
    func footnoteAsides(itemId: String) -> Bool {
        guard let item = try? store.loadItem(id: itemId), let text = Self.preparedText(of: item, in: store) else { return false }
        return Self.footnoteAsides(item: item, articleText: text, store: store)
    }

    static func footnoteAsides(item: Item, articleText: String, store: SQLiteSessionStore?) -> Bool {
        // Most articles have no note: no manifest read.
        guard NarrationChunkPlanner.hasFootnotesToReadWhereCited(in: articleText) else { return false }
        // A read that fails (a busy database, one undecodable row) answers plain: with the manifests unknown, a notes
        // plan could replace a ready plain preparation, and plain never replaces anything that is there.
        let manifests: [PreparedAudioManifest]
        if let store {
            guard let loaded = try? store.loadPreparedAudioManifests(itemId: item.id) else { return false }
            manifests = loaded
        } else {
            manifests = []
        }
        return FootnotePlanDecision.asides(
            mode: FootnoteMode(storedValue: UserDefaults.standard.string(forKey: FootnoteMode.storageKey)),
            isPDF: item.mediaType == "pdf", articleText: articleText, manifests: manifests)
    }

    /// The item's prepared text and the plan kind `articleIdentity` names, while the player's article plan is still for
    /// it. A turn is not a Library item, and a changed article matches nothing (#312).
    private func planSource(itemId: String, articleIdentity: String) -> (text: String, asides: Bool)? {
        guard let text = articleText(itemId: itemId),
              let asides = NarrationChunkPlanner.planUsesAsides(identity: articleIdentity, ofArticle: text) else { return nil }
        return (text, asides)
    }

    func planned(itemId: String, articleIdentity: String, plan: [PreparedChunkPlan]) async {
        guard let signature = try? await signatureTask.value,
              let source = planSource(itemId: itemId, articleIdentity: articleIdentity) else { return }
        _ = try? await coordinator.begin(itemId: itemId, sourceText: source.text, signature: signature, plan: plan,
                                         schedulesJob: false, asides: source.asides)
    }

    func rendered(itemId: String, articleIdentity: String, plan: PreparedChunkPlan, audioURL: URL, durationMs: Int, engine: String) async {
        guard let signature = try? await signatureTask.value,
              let source = planSource(itemId: itemId, articleIdentity: articleIdentity) else { return }
        try? await coordinator.commit(itemId: itemId, signature: signature, plan: plan, sourceText: source.text, audioURL: audioURL,
                                      durationMs: durationMs, engine: engine, asides: source.asides)
    }

    /// `engine` nil: the voice's own saved audio. Another engine: that engine's saved stand-in (#1680).
    func lookup(itemId: String, articleIdentity: String, plan: PreparedChunkPlan, engine: String? = nil) async -> PreparedChunkLookupResult? {
        guard let signature = try? await signatureTask.value,
              let source = planSource(itemId: itemId, articleIdentity: articleIdentity) else { return nil }
        return try? await coordinator.committedChunk(itemId: itemId, signature: signature, plan: plan, sourceText: source.text,
                                                     engine: engine, asides: source.asides)
    }
}
