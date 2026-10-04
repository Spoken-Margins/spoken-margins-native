import Foundation
import SessionKit
import SessionKitPersistence
@preconcurrency import AVFoundation

/// Sends an episode's transcript to the owner's server once, so it can make a community
/// listening map, when the listener opted in (#552). The rules and the request body live in
/// SessionKit (`CommunityMapUploadPolicy`, `CommunityMapUploader`); this gathers what they need
/// after a transcript is attached and puts the outcome in Diagnostics. Failures are silent.
@MainActor
final class CommunityMapUploadService {
    /// Settings > Support & Privacy > "Help make listening maps". Off unless the listener turns it on.
    static let optInKey = "communityMapUploadOptIn"
    static let shared = CommunityMapUploadService()

    private let uploader = CommunityMapUploader(post: CommunityMapTransport.post)
    private lazy var bridge = BridgeService.makeStore()
    /// Episode keys being sent, so two Library copies of one episode can't both upload.
    private var inFlight: Set<String> = []

    /// After a transcript is attached: the first try for that episode. `localAudio` finds the
    /// item's downloaded file, which is read for chapters embedded in the audio.
    func transcriptAttached(
        itemId: String,
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        // Opted out: read nothing, send nothing, not even a config request.
        guard Self.optedIn else { return }
        attempt(itemId: itemId, store: store, localAudio: localAudio, report: report)
    }

    /// When the app becomes active: retries uploads that were held back or failed a day or more
    /// ago (offline, busy, switched off, at the spend cap, audio not yet downloaded), since a
    /// transcript is attached only once per item.
    func retryFailed(
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard Self.optedIn, let records = try? store.loadCommunityMapUploads() else { return }
        for var record in CommunityMapUploadPolicy.dueForRetry(records, now: Date()).prefix(3) {
            guard (try? store.loadItem(id: record.itemId)) != nil,
                  (try? store.loadTranscriptTimeline(itemId: record.itemId)) != nil else {
                // The item or its transcript is gone for good: close the record so it stops
                // coming back first in every retry.
                record.state = .rejected
                record.lastAttemptAt = Date()
                record.lastOutcome = "skipped:item_gone"
                try? store.saveCommunityMapUpload(record)
                continue
            }
            attempt(itemId: record.itemId, store: store, localAudio: localAudio, report: report)
        }
    }

    private static var optedIn: Bool { UserDefaults.standard.bool(forKey: optInKey) }

    private func attempt(
        itemId: String,
        store: SQLiteSessionStore,
        localAudio: @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard let item = try? store.loadItem(id: itemId),
              let episodeKey = CommunityMapEpisodeKey.key(for: item),
              !inFlight.contains(episodeKey),
              let timeline = try? store.loadTranscriptTimeline(itemId: itemId)?.timeline else { return }
        let storedChapters = CommunityMapUploadPolicy.hasPublisherChapters(
            map: try? store.loadListeningMap(itemId: itemId), timeline: timeline
        )
        // Chapters embedded in the audio are imported only once the file is read, which can
        // finish after the transcript is attached, so they are read here too.
        let audioFile = localAudio(itemId)
        // Transcripts don't record their language (a publisher's VTT can be in any language), and
        // the device's would mislabel them, so the server is told it's unknown.
        let language = "und"
        let bridge = self.bridge
        let uploader = self.uploader
        inFlight.insert(episodeKey)
        Task {
            let outcome = await uploader.uploadIfEligible(
                item: item, timeline: timeline, language: language, repository: store,
                optedIn: { await MainActor.run { Self.optedIn } },
                publisherChapters: {
                    if storedChapters { return true }
                    guard let audioFile else { return nil }
                    return await Self.hasEmbeddedChapters(audioFile)
                },
                mapsState: {
                    guard let bridge else { return .off(.noConfig) }
                    await bridge.refreshConfigOnly()
                    return await bridge.state(of: ServerService.maps)
                }
            )
            self.inFlight.remove(episodeKey)
            report(outcome.diagnostic)
        }
    }

    /// Whether the audio file carries chapters, or nil when it couldn't be read (gone, or still
    /// being replaced), so a failed read holds the upload instead of counting as "no chapters".
    private nonisolated static func hasEmbeddedChapters(_ file: URL) async -> Bool? {
        guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        let asset = AVURLAsset(url: file)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages
        ) else { return nil }
        return !groups.isEmpty
    }
}
