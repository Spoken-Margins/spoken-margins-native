import Foundation
import SessionKit
import SessionKitPersistence

/// What "Hear it as your friend will" needs from the model (#4171, PR 4b). The preview itself is
/// `LeadInPreviewPlayer`; its rules are `SenderLeadInPreview`. Nothing here plays or changes playback state beyond a
/// pause.
extension Gate1AppModel {
    /// The episode the preview plays from: its downloaded file, else its stream. Nil when neither is there, which the
    /// preview reports as "needs the episode downloaded, or a connection".
    func senderPreviewEpisodeURL(itemId: String) -> URL? {
        if let local = podcastDownloadCoordinator?.validatedLocalURL(for: itemId) { return local }
        guard let item = try? store?.loadItemSummary(id: itemId) else { return nil }
        if item.mediaType == "audiobook" { return resolvedOwnedAudiobookURL(for: item) }
        if SpokenNoteItem.isSpokenNote(mediaType: item.mediaType) {
            return (try? applicationSupportDirectory()).flatMap { SpokenNoteWholePlayback.playbackURL(for: item, applicationSupport: $0) }
        }
        guard let raw = item.media?.url, let url = URL(string: raw) else { return nil }
        if url.isFileURL {
            return resolvedApplicationSupportAssetURL(for: url.path).flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
        }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    }

    /// Starting the preview pauses the main player if it's playing, and leaves it paused (Design §2).
    func pauseForSenderPreview() {
        guard snapshot.status.isPlaybackActive else { return }
        pause()
    }
}
