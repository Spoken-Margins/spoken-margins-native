import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
import SessionKitSharing

/// Lets the listener say which podcast episode an audio file they imported is (#755), so a packet a friend
/// shared by link lands on the file instead of adding a second, streamed copy. The rules for what may be
/// linked live in `ImportedFileEpisodeLink` (SessionKit); this reads the pasted link and saves the result.
struct ImportedFileEpisodeLinker {
    /// What the item screen shows for an item: whether the link can be set, and the episode it is set to.
    struct Status: Equatable {
        var canLink = false
        var episodeTitle: String?
        /// False once Margins a friend shared by link sit on the file under its episode: changing it would orphan them.
        var canChange = true
    }

    var resolve: @Sendable (LinkResolutionRequest) async throws -> LinkResolutionResult = {
        try await PublicPodcastLinkResolver().resolveAsync($0)
    }

    /// Reads on a background thread (#2507): the item, its layers and the owned-audio table are one read, and a
    /// listener with a long Library no longer waits on them with the item screen open.
    /// Nil when a newer status read started meanwhile (its answer is the one to show) or the read failed.
    func status(itemId: String, store: SQLiteSessionStore) async -> Status? {
        let status = try? await StoreReader(store).readLatest("episodeLinkStatus:" + itemId) { store in
            guard let item = try? store.loadItem(id: itemId),
                  item.mediaType == "audiobook", item.media?.sourceType == .nativeMediaFile else { return Status() }
            return Status(
                canLink: true,
                episodeTitle: item.linkedEpisode.map { $0.title.isEmpty ? "Podcast episode" : $0.title },
                canChange: !Self.hasLinkedMargins(item: item, store: store)
            )
        }
        return status ?? nil
    }

    /// Layers that stay on the file only through its episode link. Margins from a packet that names the exact
    /// file do not count, so a wrong link stays fixable when only those are there. Runs inside a background read.
    nonisolated private static func hasLinkedMargins(item: Item, store: SQLiteSessionStore) -> Bool {
        let layers = (try? store.loadImportedCommentaryLayers(itemId: item.id)) ?? []
        let digest = SharedPacketItemMatcher.ownedAudiobookDigest(
            for: item, assets: (try? store.loadOwnedOfflineAssets()) ?? []
        )
        return !SharedPacketItemMatcher.layersDependingOnEpisodeLink(layers, item: item, ownedAudiobookDigest: digest).isEmpty
    }

    /// Resolves the pasted link and links the file to the episode it names. Returns the episode's title.
    /// Throws `ImportedFileEpisodeLink.Refusal` (with a listener-facing message) when the link cannot be used.
    @MainActor
    func link(itemId: String, to pastedLink: String, store: SQLiteSessionStore) async throws -> String {
        let pasted = pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: pasted)?.scheme?.lowercased() == "https" else {
            throw ImportedFileEpisodeLink.Refusal.couldNotReadLink
        }
        let reader = StoreReader(store)
        try await reader.read { try Self.requireChangeable(itemId: itemId, store: $0) }
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
        return try await reader.read { store in
            let linked = try ImportedFileEpisodeLink.link(try store.loadItem(id: itemId), resolution: result, pageURL: pasted)
            try store.saveItem(linked)
            return linked.linkedEpisode?.title ?? "the episode"
        }
    }

    func unlink(itemId: String, store: SQLiteSessionStore) async throws {
        try await StoreReader(store).read { store in
            try Self.requireChangeable(itemId: itemId, store: store)
            try store.saveItem(ImportedFileEpisodeLink.unlink(try store.loadItem(id: itemId)))
        }
    }

    /// Margins placed through the linked episode would lose their file if the link changed or went away.
    nonisolated private static func requireChangeable(itemId: String, store: SQLiteSessionStore) throws {
        if hasLinkedMargins(item: try store.loadItem(id: itemId), store: store) {
            throw ImportedFileEpisodeLink.Refusal.hasSharedMargins
        }
    }
}
