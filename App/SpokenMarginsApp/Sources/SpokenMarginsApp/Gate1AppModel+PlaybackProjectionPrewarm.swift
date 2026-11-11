import Foundation
import SessionKit
import SessionKitPersistence

/// A play of a text item hands its whole text, preface included, to the voice, which projects it into what is spoken:
/// 282 ms on the main thread for a long article, in the middle of the tap (#2256). Opening the item does that
/// projection first, off the main thread, so the play finds it ready. The result lives in `SpeechTextNormalizer`'s
/// memo, matched by the text itself, so a text that changes in between is simply projected again.
///
/// A PDF's listenable text (its document, then the projection of what is read aloud) is built in the same pass and
/// handed to the engine, which keeps it for the first play. The engine accepts it only if no document was saved since
/// the generation read here, before the work started.
extension Gate1AppModel {
    func prewarmPlaybackProjection(itemId: String, store: SQLiteSessionStore) {
        guard audioPlaybackClientOverride == nil else { return } // a test's own player projects what it likes
        let kinds = SpeechTextNormalizer.PrewarmVoiceKinds.forSelection(onDeviceVoice: ttsVoiceSelection.isOnDeviceVoice)
        // The engine and its generation as they are now, on the main actor. With no engine yet there is nothing to hand to.
        let engineAtStart = engine
        let generationAtStart = engineAtStart?.listenableProjectionGeneration
        Task(priority: .utility) {
            // The store is read and the text projected on the reader's own thread, never on the main actor.
            let prewarmed = try? await StoreReader(store).read(priority: .utility) { store -> PrewarmedListenableProjection? in
                // An item with its publisher's recording may play that, not the text: nothing to project ahead.
                guard (try? store.loadPublisherAudio(itemId: itemId)) == nil else { return nil }
                return ItemPlaybackText.prewarmProjection(itemId: itemId, repository: store, kinds: kinds)
            }
            // Back on the main actor. A different engine (a store reopened meanwhile) has its own caches: skip.
            if let prewarmed, let engineAtStart, let generationAtStart, engine === engineAtStart {
                engineAtStart.adoptPrewarmedListenableProjection(prewarmed, generation: generationAtStart)
            }
        }
    }
}
