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

    /// Why a post added from Following kept, or didn't keep, its publisher's voice (#2024): the item it was added as,
    /// the lookup's token (`not_substack:…`, `short_body:<words>`, `fetch_failed:…`, `none:<page absence>`,
    /// `found:…`), and whether a record was saved for that item.
    func recordFollowedPublisherAudio(_ outcome: String?, itemId: String?, saved: Bool) {
        diagnostics["followedPublisherAudio"] = "\(itemId ?? "not_imported"): \(outcome ?? "no_lookup"); record=\(saved ? "saved" : "none")"
    }

    func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        guard !playsPublisherAudio(itemId: itemId) else { return }
        prewarmTextAudioForOnDeviceVoice(itemId: itemId)
    }
}
