import Foundation
import SessionKit
import SessionKitPersistence

/// An article with its publisher's recording and a text-to-time map plays the recording (#547), so
/// nothing is rendered ahead for its on-device voice. Kept out of `Gate1AppModel.swift` to stay under
/// its size ceiling (scripts/hot_file_ratchet.py).
extension Gate1AppModel {
    func playsPublisherAudio(itemId: String) -> Bool {
        guard let store, let item = try? store.loadItem(id: itemId) else { return false }
        return PublisherAudioPlayback.plan(for: item, record: try? store.loadPublisherAudio(itemId: itemId)) != nil
    }

    func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        guard !playsPublisherAudio(itemId: itemId) else { return }
        prewarmTextAudioForOnDeviceVoice(itemId: itemId)
    }
}
