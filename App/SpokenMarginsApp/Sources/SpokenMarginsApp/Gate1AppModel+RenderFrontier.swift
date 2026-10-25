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

    /// One frontier read, store and files both off the main thread (#2652, #2256).
    func readRenderFrontier(store: SQLiteSessionStore, itemID: String, signature: TTSRenderSignature, text: String, canonical: String, root: URL) async throws -> Double {
        try await Task.detached(priority: .utility) {
            let manifest = try store.loadPreparedAudioManifests(itemId: itemID).first { $0.signature == signature }
            return PreparedRenderFrontier.fraction(manifest: manifest, signature: signature, sourceText: text, canonicalSourceText: canonical, root: root)
        }.value
    }
}
