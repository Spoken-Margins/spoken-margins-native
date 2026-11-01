import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// The model's side of placing a shared podcast Margin on the listener's own copy of the episode (#1012, #1015).
/// The state and the work live in `ImportedPodcastPlacementCoordinator`; this extension builds it from what only the
/// model can supply and forwards the model's entry points to it.
extension Gate1AppModel {
    /// Placement work in flight, so shared Margins read "placing", not "unresolved" (#872).
    var sharedMarginPlacementPasses: SharedMarginPlacementPasses { importedPodcastPlacement.passes }

    func makeImportedPodcastPlacementCoordinator() -> ImportedPodcastPlacementCoordinator {
        ImportedPodcastPlacementCoordinator(dependencies: .init(
            store: { [weak self] in self?.store },
            transcriber: sourceTranscriptionClient,
            deferPlacement: { [weak self] item, localURL in
                self?.deferPlacementWhileSessionKeepsItsEdition(item: item, localURL: localURL) ?? false
            },
            clearDeferredPlacement: { [weak self] itemId in self?.deferredPodcastPlacementURLs[itemId] = nil },
            localAudiobookDigest: { [weak self] item in self?.localAudiobookDigest(for: item) },
            applicationSupportDirectory: { [weak self] in try? self?.applicationSupportDirectory() },
            listenerHasListeningMap: { itemId, store in try Gate1AppModel.listenerHasListeningMap(itemId: itemId, store: store) },
            purgeTransientCaches: { [weak self] itemId in try await self?.purgeTransientEpisodeTranscriptionCaches(itemId: itemId) },
            prepareSummaryBridgeAsset: { [weak self] itemId, proposalId, scene, store in
                _ = try? await self?.prepareSummaryBridgeAsset(itemId: itemId, proposalId: proposalId, scene: scene, store: store)
            },
            updateSkimAvailability: { [weak self] in self?.updateSkimAvailability() },
            refreshAfterInvalidation: { [weak self] itemId in
                guard let self else { return }
                if self.selectedItem.id == itemId { self.refreshSelectedItemInBackground() }
                self.refreshMarginRowsInBackground(forItem: itemId)
            },
            refreshSelectedItemIfShowing: { [weak self] itemId in
                guard let self else { return }
                if self.selectedItem.id == itemId { self.refreshSelectedItemInBackground() }
            },
            recordDiagnostic: { [weak self] key, value in self?.diagnostics[key] = value },
            passesDidChange: { [weak self] old, new in
                guard let self else { return }
                if old.pass(itemId: self.activeItemId) != new.pass(itemId: self.activeItemId) { self.refreshSelectedItemInBackground() }
                if old != new { self.refreshMarginRowsInBackground() }
            },
            retainHost: { [weak self] in self }
        ))
    }

    func scheduleTransientRecipientAlignmentTranscript(for item: some LibraryItemFields, localSourceURL: URL) {
        importedPodcastPlacement.scheduleTransientTranscript(for: item, localSourceURL: localSourceURL)
    }

    func resolveImportedPodcastCommentary(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) {
        importedPodcastPlacement.resolve(
            itemId: itemId, localURL: localURL, recipientTranscriptOverride: recipientTranscriptOverride)
    }

    func importedPodcastCommentaryNeedsTranscript(
        itemId: String,
        store: SQLiteSessionStore
    ) -> Bool {
        importedPodcastPlacement.commentaryNeedsTranscript(itemId: itemId, store: store)
    }
}
