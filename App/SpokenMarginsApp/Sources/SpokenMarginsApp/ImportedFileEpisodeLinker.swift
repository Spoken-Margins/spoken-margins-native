import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// Lets the listener say which podcast episode an audio file they imported is (#755), so a packet a friend
/// shared by link lands on the file instead of adding a second, streamed copy. The rules for what may be
/// linked live in `ImportedFileEpisodeLink` (SessionKit); this reads the pasted link and saves the result.
struct ImportedFileEpisodeLinker {
    /// What the item screen shows for an item: whether the link can be set, and the episode it is set to.
    struct Status: Equatable {
        var canLink = false
        var episodeTitle: String?
    }

    var resolve: @Sendable (LinkResolutionRequest) async throws -> LinkResolutionResult = {
        try await PublicPodcastLinkResolver().resolveAsync($0)
    }

    @MainActor
    func status(itemId: String, store: SQLiteSessionStore) -> Status {
        guard let item = try? store.loadItem(id: itemId),
              item.mediaType == "audiobook", item.media?.sourceType == .nativeMediaFile else { return Status() }
        return Status(canLink: true, episodeTitle: item.linkedEpisode.map { $0.title.isEmpty ? "Podcast episode" : $0.title })
    }

    /// Resolves the pasted link and links the file to the episode it names. Returns the episode's title.
    /// Throws `ImportedFileEpisodeLink.Refusal` (with a listener-facing message) when the link cannot be used.
    @MainActor
    func link(itemId: String, to pastedLink: String, store: SQLiteSessionStore) async throws -> String {
        let pasted = pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: pasted)?.scheme?.lowercased() == "https" else {
            throw ImportedFileEpisodeLink.Refusal.couldNotReadLink
        }
        let request = LinkResolutionRequest(
            id: "imported-file-episode-\(UUID().uuidString)", inputURL: pasted,
            sourceSurface: "imported_file_episode_link", createdAt: Date()
        )
        let result: LinkResolutionResult
        do {
            result = try await resolve(request)
        } catch {
            throw ImportedFileEpisodeLink.Refusal.couldNotReadLink
        }
        // Load after the wait: the item may have changed while the link was being read.
        let linked = try ImportedFileEpisodeLink.link(try store.loadItem(id: itemId), resolution: result, pageURL: pasted)
        try store.saveItem(linked)
        return linked.linkedEpisode?.title ?? "the episode"
    }

    @MainActor
    func unlink(itemId: String, store: SQLiteSessionStore) throws {
        try store.saveItem(ImportedFileEpisodeLink.unlink(try store.loadItem(id: itemId)))
    }
}
