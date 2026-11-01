import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Reacts when a podcast file is ready locally and starts playback from the right file (#1012), moved unchanged out of the central model.
extension Gate1AppModel {
    func podcastLocalAssetDidBecomeReady(itemId: String, url: URL) {
        guard let engine, let store else { return }
        importedPodcastRecipientLocalURLs[itemId] = url
        let requestedReplacement = requestedPodcastTransportReplacements.remove(itemId) != nil
        run { _ in
            // Automatic completion keeps the current session's audio edition.
            // Explicit Download Again and a pending startup may adopt the new
            // file, including when a paused session's old local file was replaced.
            snapshot = try engine.updatePlaybackTransport(
                itemId: itemId,
                playbackURL: url.absoluteString,
                replaceActivePlayback: snapshot.status == .starting || requestedReplacement
            )
            refreshSelectedItem()
        }
        if requestedReplacement, let record = podcastDownloadRecords[itemId] { reportConfirmation(PodcastDownloadStatusText.downloaded(record) + ".") }
        scheduleEmbeddedPublisherChapterImport(itemId: itemId, localURL: url)
        retrySourceWindowContexts(itemId: itemId)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: url)
        // Placement reads the item off the main thread and decides later (#2507), so the deferral it records is not
        // there yet. Ask the #914 question here instead: a stream the session keeps gets no transcript of the download.
        if importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store),
           let item = try? store.loadItemSummary(id: itemId), // a summary answers the stream check and the duration; the article text stays on disk (#2506)
           !deferPlacementWhileSessionKeepsItsEdition(item: item, localURL: url) {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_for_imported_commentary"
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: url)
            return
        }
        guard pendingMapGenerationItemId == itemId,
              (try? store.loadItemSummary(id: itemId)) != nil else {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "not_requested"
            return
        }
        pendingMapGenerationItemId = nil
        diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_private_episode_map"
        prepareEpisodeMap(itemId: itemId, policy: .explicit, trigger: .downloadFinished)
    }

    private func scheduleEmbeddedPublisherChapterImport(itemId: String, localURL: URL) {
        Task { @MainActor [weak self] in
            guard let collection = await EmbeddedPublisherChapterLoader.load(from: localURL),
                  let self,
                  let engine = self.engine else {
                self?.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "not_found"
                return
            }
            self.run { _ in
                self.snapshot = try engine.attachPublisherChapters(itemId: itemId, collection: collection)
                if self.activeItemId == itemId {
                    self.refreshSelectedItemInBackground()
                }
                self.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "imported_\(collection.chapters.count)"
            }
        }
    }

    func schedulePodcastDownloadIfNeeded(itemId: String) {
        guard let store,
              let item = try? store.loadItemSummary(id: itemId),
              item.media?.sourceType == .remoteStream,
              let rawURL = item.media?.url,
              let remoteURL = URL(string: rawURL) else { return }
        podcastDownloadCoordinator?.register(itemId: itemId, remoteURL: remoteURL)
    }

    func resolvedOwnedAudiobookURL(for item: some LibraryItemFields) -> URL? {
        // iOS can relocate the data container during an update. The ledger path
        // is relative to today's Application Support directory; item URLs are not.
        if let assets = try? store?.loadOwnedOfflineAssets(itemId: item.id),
           let asset = assets.first(where: { $0.category == .audiobook && $0.integrity == .valid }),
           let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) {
            return url
        }
        guard let savedURL = item.media?.url.flatMap(URL.init(string:)), savedURL.isFileURL else { return nil }
        return resolvedApplicationSupportAssetURL(for: savedURL.path)
    }

    func prepareSourceMediaPlayback(itemId: String) throws {
        // A missing item throws, as the whole-item read did.
        let summary = try store.map { store -> LibraryItemSummary in
            guard let summary = try store.loadItemSummary(id: itemId) else { throw SessionKitError.missingFixture("item:\(itemId)") }
            return summary
        }
        if let item = summary, item.mediaType == "audiobook" {
            guard let url = resolvedOwnedAudiobookURL(for: item) else {
                throw SessionKitError.invalidCommandForState("The imported audio file is unavailable. Restore the source audio to continue listening.")
            }
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: url.absoluteString, replaceActivePlayback: false)
            return
        }
        guard let coordinator = podcastDownloadCoordinator else { return }
        coordinator.configureActiveItem(itemId)
        if let record = podcastDownloadRecords[itemId], record.state == .evicted,
           coordinator.networkTransport == .wifi,
           let remoteURL = URL(string: record.remoteURL) {
            coordinator.register(itemId: itemId, remoteURL: remoteURL)
        }
        guard let localURL = coordinator.validatedLocalURL(for: itemId) else {
            // Clear a cached local override when its file has disappeared.
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: nil, replaceActivePlayback: false)
            return
        }
        _ = try? engine?.updatePlaybackTransport(itemId: itemId, playbackURL: localURL.absoluteString, replaceActivePlayback: false)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
    }
}
