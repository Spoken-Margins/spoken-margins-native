import Foundation
import SessionKit
import SessionKitAudio

/// Shared podcast Margins are placed against the edition the listener hears (#914). A session that started on the
/// stream keeps it when the download finishes, so placing against the file at once would play Margins at the wrong moment.
extension Gate1AppModel {
    /// True when placement must wait: a streamed episode whose session plays another file. Remembers the download
    /// for `resumeDeferredPodcastPlacements`; otherwise clears any earlier deferral.
    func deferPlacementWhileSessionKeepsItsEdition(item: Item, localURL: URL) -> Bool {
        if item.media?.sourceType == .remoteStream,
           engine?.mediaSessionPlays(itemId: item.id, playbackURL: localURL.absoluteString) == false {
            deferredPodcastPlacementURLs[item.id] = localURL
            diagnostics["podcastPlacementDeferred:\(item.id)"] = "session_keeps_its_edition"
            return true
        }
        deferredPodcastPlacementURLs[item.id] = nil
        return false
    }

    /// The session changed, so the next one starts on the finished download: place the Margins against it now.
    func resumeDeferredPodcastPlacements() {
        guard !deferredPodcastPlacementURLs.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hangTelemetry.labels.scoped("resumeDeferredPlacements") {
                for (itemId, localURL) in self.deferredPodcastPlacementURLs {
                    self.diagnostics["podcastPlacementDeferred:\(itemId)"] = "resumed_after_session_change"
                    self.resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                }
            }
        }
    }
}
