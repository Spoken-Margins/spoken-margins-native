import Foundation
import SessionKit
import SessionKitPersistence

/// A play of a text item hands its whole text, preface included, to the voice, which projects it into what is spoken:
/// 282 ms on the main thread for a long article, in the middle of the tap (#2256). Opening the item does that
/// projection first, off the main thread, so the play finds it ready. The result lives in `SpeechTextNormalizer`'s
/// memo, matched by the text itself, so a text that changes in between is simply projected again.
extension Gate1AppModel {
    func prewarmPlaybackProjection(itemId: String, store: SQLiteSessionStore) {
        guard audioPlaybackClientOverride == nil else { return } // a test's own player projects what it likes
        let forSystemSpeech = !ttsVoiceSelection.isOnDeviceVoice
        Task(priority: .utility) {
            // The store is read and the text projected on the reader's own thread, never on the main actor.
            try? await StoreReader(store).read(priority: .utility) { store in
                // An item with its publisher's recording may play that, not the text: nothing to project ahead.
                guard (try? store.loadPublisherAudio(itemId: itemId)) == nil else { return }
                ItemPlaybackText.prewarmProjection(itemId: itemId, repository: store, forSystemSpeech: forSystemSpeech)
            }
        }
    }
}
