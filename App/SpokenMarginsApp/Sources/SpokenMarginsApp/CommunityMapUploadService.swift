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
    private var inFlight: Set<String> = []

    /// After a transcript is attached: the first try for that episode.
    func transcriptAttached(itemId: String, store: SQLiteSessionStore, report: @escaping @MainActor (String) -> Void) {
        // Opted out: read nothing, send nothing, not even a config request.
        guard Self.optedIn else { return }
        attempt(itemId: itemId, store: store, report: report)
    }

    /// When the app becomes active: retries uploads that failed a day or more ago (offline, busy,
    /// switched off, at the spend cap), since a transcript is attached only once per item.
    func retryFailed(store: SQLiteSessionStore, report: @escaping @MainActor (String) -> Void) {
        guard Self.optedIn, let records = try? store.loadCommunityMapUploads() else { return }
        for record in CommunityMapUploadPolicy.dueForRetry(records, now: Date()).prefix(3) {
            attempt(itemId: record.itemId, store: store, report: report)
        }
    }

    private static var optedIn: Bool { UserDefaults.standard.bool(forKey: optInKey) }

    private func attempt(itemId: String, store: SQLiteSessionStore, report: @escaping @MainActor (String) -> Void) {
        guard !inFlight.contains(itemId),
              let item = try? store.loadItem(id: itemId),
              let timeline = try? store.loadTranscriptTimeline(itemId: itemId)?.timeline else { return }
        let hasPublisherChapters = CommunityMapUploadPolicy.hasPublisherChapters(
            map: try? store.loadListeningMap(itemId: itemId), timeline: timeline
        )
        // The source transcriber listens in the device's language (`SpeechTranscriber` with `Locale.current`).
        let language = Locale.current.identifier(.bcp47)
        let bridge = self.bridge
        let uploader = self.uploader
        inFlight.insert(itemId)
        Task {
            let outcome = await uploader.uploadIfEligible(
                item: item, timeline: timeline, hasPublisherChapters: hasPublisherChapters, optedIn: true,
                language: language, repository: store
            ) {
                guard let bridge else { return .off(.noConfig) }
                await bridge.refreshConfigOnly()
                return await bridge.state(of: ServerService.maps)
            }
            self.inFlight.remove(itemId)
            report(outcome.diagnostic)
        }
    }
}
