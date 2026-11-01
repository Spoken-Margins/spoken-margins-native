import Foundation
import SessionKit

extension Gate1AppModel {
    /// A podcast episode with no chapters and no map of its own asks the server for a community map (#553).
    func fetchCommunityMapIfNeeded(itemId: String) {
        guard let store else { return }
        CommunityMapFetchService.shared.episodeOpened(
            itemId: itemId, store: store,
            localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) },
            didStore: { [weak self] in self?.communityMapStored(itemId: itemId) },
            report: { [weak self] in self?.diagnostics["communityMapFetch"] = $0 }
        )
    }

    /// The scenes show on the item page now, and Skim's summaries are rendered like any stored map's.
    private func communityMapStored(itemId: String) {
        if itemId == activeItemId { refreshSelectedItemInBackground() }
        prepareImportedLocalAudioBridges(itemId: itemId)
        if itemId == activeItemId { updateSkimAvailability() }
    }
}
