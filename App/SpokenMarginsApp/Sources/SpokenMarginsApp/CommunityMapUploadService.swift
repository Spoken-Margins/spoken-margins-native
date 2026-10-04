import Foundation
import SessionKit
import SessionKitPersistence

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
        for record in CommunityMapUploadPolicy.dueForRetry(records, now: Date()).prefix(3) {
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
        // The source transcriber listens in the device's language (`SpeechTranscriber` with `Locale.current`).
        let language = Locale.current.identifier(.bcp47)
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
                    return await EmbeddedPublisherChapterLoader.load(from: audioFile) != nil
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
}
