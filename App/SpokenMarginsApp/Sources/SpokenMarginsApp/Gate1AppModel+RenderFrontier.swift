import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic

extension Gate1AppModel {
    /// The render identity for a voice, cached. Saved audio shows before the model is downloaded too (#1820).
    func renderFrontierSignature(for voice: SupertonicVoiceID) async throws -> TTSRenderSignature {
        if let cached = frontierSignatures[voice.rawValue] { return cached }
        let signature = try await Task.detached(priority: .utility) {
            try SupertonicRenderIdentity.current(voice: voice)
        }.value
        frontierSignatures[voice.rawValue] = signature
        return signature
    }

    /// The item's prepared text and its canonical source text, read off the main thread: opening the playback screen
    /// used to decode the whole article here twice on main (#2506). Nil when there is nothing to measure against.
    func renderFrontierTexts(store: SQLiteSessionStore, itemID: String) async throws -> (text: String, canonical: String)? {
        try await StoreReader(store).read { try Self.loadRenderFrontierTexts(store: $0, itemID: itemID) }
    }

    nonisolated static func loadRenderFrontierTexts(store: SQLiteSessionStore, itemID: String) throws -> (text: String, canonical: String)? {
        let item = try store.loadItem(id: itemID)
        guard let text = PreparedSpeechHooks.preparedText(of: item, in: store), !text.isEmpty else { return nil }
        let source = try store.loadCanonicalSource(itemId: itemID)
        return (text, source?.segments.map(\.text).joined(separator: "\n\n") ?? "")
    }

    /// One frontier read, store and files both off the main thread (#2652, #2256).
    func readRenderFrontier(store: SQLiteSessionStore, itemID: String, signature: TTSRenderSignature, text: String, canonical: String, root: URL) async throws -> Double {
        try await Task.detached(priority: .utility) {
            let manifest = try store.loadPreparedAudioManifests(itemId: itemID).first { $0.signature == signature }
            return PreparedRenderFrontier.fraction(manifest: manifest, signature: signature, sourceText: text, canonicalSourceText: canonical, root: root)
        }.value
    }
}
