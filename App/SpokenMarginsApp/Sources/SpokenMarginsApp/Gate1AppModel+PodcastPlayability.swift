import Foundation
import SessionKit
import SessionKitPersistence

/// Podcast episodes that can't play: no signal (#779), a stalled start, a failed download.
extension Gate1AppModel {
    func stopStalledPodcastStart(itemID: String) {
        guard snapshot.itemId == itemID, snapshot.status == .starting,
              selectedPodcastDownloadState != nil else { return }
        pause()
        // A saved file, even one that turns out broken, is what "Download Again" can replace.
        reportFailure(OfflinePlayability.episodeStalledMessage(
            hasSavedAudio: podcastDownloadRecords[itemID]?.localRelativePath != nil,
            isOffline: connectivity.isOffline
        ))
    }

    /// A streamed-only episode started with no signal says so, instead of trying and stalling (#779).
    /// Returns true when it reported that and the caller must not start playback.
    func blockOfflineEpisodeStart(itemId: String) -> Bool {
        guard connectivity.isOffline,
              let item = try? store?.loadItemSummary(id: itemId),
              item.media?.sourceType == .remoteStream,
              let message = OfflinePlayability.episodeStartBlockedMessage(
                  hasSavedAudio: podcastDownloadCoordinator?.validatedLocalURL(for: itemId) != nil,
                  isOffline: true
              ) else { return false }
        reportFailure(message, itemId: itemId)
        return true
    }

    func retrySelectedPodcastDownload() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download retry is unavailable.")
            return
        }
        podcastDownloadCoordinator?.retry(itemId: selectedItem.id)
        reportSuccess("Retrying podcast download.")
    }
}
