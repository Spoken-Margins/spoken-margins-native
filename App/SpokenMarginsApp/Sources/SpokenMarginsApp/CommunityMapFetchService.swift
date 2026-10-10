import Foundation
import SessionKit
import SessionKitPersistence

/// Asks the owner's server for a community listening map when a podcast episode with no chapters
/// and no map of its own opens (#553). The rules, the request and the conversion live in
/// SessionKit (`CommunityMapFetchPolicy`, `CommunityMapFetcher`, `CommunityMapConverter`); this
/// gathers what they need and stores the map as an ordinary proposal and projection. The model
/// then renders the Skim summaries the way it does for any map it holds. Nothing is shown to the
/// listener when anything goes wrong.
@MainActor
final class CommunityMapFetchService {
    static let shared = CommunityMapFetchService()
    /// Until when each episode isn't asked about again, as hashes and dates only.
    static let logKey = "communityMapFetchLog"

    private let fetcher = CommunityMapFetcher(get: BridgePublicTransport.fetch)
    private lazy var bridge = BridgeService.makeStore()
    /// Item ids being asked about, so opening an episode twice runs once.
    private var inFlight: Set<String> = []

    /// When an episode opens or starts. `didStore` tells the model a map was stored, so it reloads
    /// the item and makes the audio for Skim's summaries.
    func episodeOpened(
        itemId: String,
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        didStore: @escaping @MainActor () -> Void,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard !inFlight.contains(itemId), let item = try? store.loadItem(id: itemId) else { return }
        let episodeKey = CommunityMapEpisodeKey.key(for: item)
        let blockedUntil = episodeKey.flatMap { Self.loadLog().blockedUntil(episodeKey: $0) }
        let audioFile = localAudio(itemId)
        let fetcher = self.fetcher
        let bridge = self.bridge
        inFlight.insert(itemId)
        Task {
            let outcome = await fetcher.fetchIfEligible(
                item: item, blockedUntil: blockedUntil,
                localState: {
                    var embedded = false
                    if let audioFile { embedded = await CommunityMapUploadService.hasEmbeddedChapters(audioFile) ?? false }
                    return CommunityMapLocalState.read(itemId: itemId, repository: store, hasEmbeddedChapters: embedded)
                },
                mapsState: {
                    guard let bridge else { return .off(.noConfig) }
                    await bridge.refreshConfigOnly()
                    return await bridge.state(of: ServerService.maps)
                },
                audioDurationMs: {
                    guard let audioFile else { return nil }
                    return await CommunityMapUploadService.measuredDurationMs(audioFile)
                },
                store: { map in try store.saveCommunityMap(proposal: map.proposal, projection: map.projection) }
            )
            if let wait = outcome.retryAfter, let episodeKey {
                var log = Self.loadLog()
                log.block(episodeKey: episodeKey, until: Date().addingTimeInterval(wait))
                Self.saveLog(log)
            }
            self.inFlight.remove(itemId)
            report(outcome.diagnostic)
            if case .stored = outcome { didStore() }
        }
    }

    private static func loadLog() -> CommunityMapFetchLog {
        UserDefaults.standard.data(forKey: logKey)
            .flatMap { try? JSONDecoder().decode(CommunityMapFetchLog.self, from: $0) } ?? CommunityMapFetchLog()
    }

    private static func saveLog(_ log: CommunityMapFetchLog) {
        UserDefaults.standard.set(try? JSONEncoder().encode(log), forKey: logKey)
    }
}
