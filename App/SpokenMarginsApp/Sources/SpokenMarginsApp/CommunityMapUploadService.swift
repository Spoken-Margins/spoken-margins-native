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
    /// A phone-made transcript that arrived while its episode was being sent, tried next.
    private var queued: [String: (itemId: String, timeline: TranscriptTimeline)] = [:]

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

    /// After the phone transcribes an episode to make its map: that transcript is not stored (the
    /// map keeps only what it needs), so it is passed here, and kept beside the upload record
    /// while the upload waits for a retry.
    func episodeTranscribed(
        itemId: String,
        timeline: TranscriptTimeline,
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard Self.optedIn else { return }
        attempt(itemId: itemId, transcribed: timeline, store: store, localAudio: localAudio, report: report)
    }

    /// When the app becomes active: retries uploads that were held back or failed a day or more
    /// ago (offline, busy, switched off, at the spend cap, audio not yet downloaded), since a
    /// transcript is attached only once per item.
    func retryFailed(
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard Self.optedIn else {
            // Opted out: nothing waits to be sent.
            Task.detached(priority: .utility) {
                if let folder = Self.keptFolder { try? FileManager.default.removeItem(at: folder) }
            }
            return
        }
        // The store reads and kept-file checks run off the main thread (#2507); only the starts come back here.
        Task {
            let due = (try? await StoreReader(store).read { store in Self.dueItemIds(store: store) }) ?? []
            for itemId in due {
                attempt(itemId: itemId, store: store, localAudio: localAudio, report: report)
            }
        }
    }

    /// The items whose held-back upload is due another try (at most three). Closes records whose item is
    /// gone and moves ones whose episode key has changed, so they stop coming back first in every retry.
    nonisolated private static func dueItemIds(store: SQLiteSessionStore) -> [String] {
        guard let records = try? store.loadCommunityMapUploads() else { return [] }
        var due: [String] = []
        for record in CommunityMapUploadPolicy.dueForRetry(records, now: Date()).prefix(3) {
            let item = try? store.loadItem(id: record.itemId)
            let kept = keptTranscript(episodeKey: record.id)
            guard CommunityMapUploadPolicy.prepareRetry(
                record, item: item,
                hasTranscript: kept != nil || (try? store.loadTranscriptTimeline(itemId: record.itemId)) != nil,
                repository: store, now: Date()
            ) else {
                keep(nil, episodeKey: record.id)
                continue
            }
            if let kept, let key = item.flatMap(CommunityMapEpisodeKey.key(for:)), key != record.id {
                keep(kept, episodeKey: key)
                keep(nil, episodeKey: record.id)
            }
            due.append(record.itemId)
        }
        return due
    }

    private static var optedIn: Bool { UserDefaults.standard.bool(forKey: optInKey) }

    private func attempt(
        itemId: String,
        transcribed: TranscriptTimeline? = nil,
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        // Also reached from a queued transcript after an upload: the setting may be off by then.
        guard Self.optedIn else { return }
        let reader = StoreReader(store)
        // Everything the upload needs is read off the main thread (#2507); the in-flight bookkeeping and
        // `localAudio` come back to it.
        Task {
            let read = try? await reader.read { store in
                Self.gather(itemId: itemId, transcribed: transcribed, store: store)
            }
            guard let gathered = read else { return }
            guard let episodeKey = gathered.episodeKey, let item = gathered.item else { return }
            guard !inFlight.contains(episodeKey) else {
                if let transcribed { queued[episodeKey] = (itemId, transcribed) }
                return
            }
            guard let timeline = gathered.timeline else { return }
            // Chapters embedded in the audio are imported only once the file is read, which can
            // finish after the transcript is attached, so they are read here too.
            let audioFile = localAudio(itemId)
            // Transcripts don't record their language (a publisher's VTT can be in any language), and
            // the device's would mislabel them, so the server is told it's unknown.
            let language = "und"
            let bridge = self.bridge
            let uploader = self.uploader
            let storedChapters = gathered.storedChapters
            inFlight.insert(episodeKey)
            let outcome = await uploader.uploadIfEligible(
                item: item, timeline: timeline, language: language, repository: store,
                optedIn: { await MainActor.run { Self.optedIn } },
                publisherChapters: {
                    if storedChapters { return true }
                    guard let audioFile else { return nil }
                    return await Self.hasEmbeddedChapters(audioFile)
                },
                audioDurationMs: {
                    guard let audioFile else { return nil }
                    return await Self.measuredDurationMs(audioFile)
                },
                mapsState: {
                    guard let bridge else { return .off(.noConfig) }
                    await bridge.refreshConfigOnly()
                    return await bridge.state(of: ServerService.maps)
                }
            )
            // Keep the phone's transcript only while its upload waits to be tried again (and if the record
            // can't be read, keep it). The episode stays in flight until this is done, so a transcript that
            // arrives meanwhile is queued, and its own attempt keeps it again.
            let hasQueued = queued[episodeKey] != nil
            _ = try? await reader.read { store in
                if case .success(let record) = Result(catching: { try store.loadCommunityMapUpload(episodeKey: episodeKey) }),
                   record?.state != .failed, !hasQueued {
                    Self.keep(nil, episodeKey: episodeKey)
                }
            }
            inFlight.remove(episodeKey)
            report(outcome.diagnostic + (gathered.unkept ? " (transcript not kept for a retry)" : ""))
            if let next = queued.removeValue(forKey: episodeKey) {
                attempt(itemId: next.itemId, transcribed: next.timeline, store: store, localAudio: localAudio, report: report)
            }
        }
    }

    /// What `attempt` reads from the store and the kept files, for one item.
    private struct Gathered: Sendable {
        var item: Item?
        var episodeKey: String?
        /// A transcript the phone made could not be saved for a retry.
        var unkept = false
        var timeline: TranscriptTimeline?
        var storedChapters = false
    }

    nonisolated private static func gather(itemId: String, transcribed: TranscriptTimeline?, store: SQLiteSessionStore) -> Gathered {
        guard let item = try? store.loadItem(id: itemId),
              let episodeKey = CommunityMapEpisodeKey.key(for: item) else { return Gathered() }
        // The map job deletes its transcript once the map is made, so the phone's transcript is
        // saved before anything is sent: an app closed mid-upload can still retry it. If it can't
        // be saved (storage full) it is still sent now, and Diagnostics says it can't be retried.
        let unkept = transcribed.map { !keep($0, episodeKey: episodeKey) } ?? false
        // A transcript the phone made for the map comes first: a stored one may be a publisher's
        // that could not upload.
        let stored = try? store.loadTranscriptTimeline(itemId: itemId)?.timeline
        let timeline = transcribed ?? keptTranscript(episodeKey: episodeKey) ?? stored
        let storedChapters = timeline.map { timeline in
            CommunityMapUploadPolicy.hasPublisherChapters(map: try? store.loadListeningMap(itemId: itemId), timeline: timeline)
                || CommunityMapUploadPolicy.hasPublisherChapters(map: nil, timeline: stored)
        } ?? false
        return Gathered(item: item, episodeKey: episodeKey, unkept: unkept, timeline: timeline, storedChapters: storedChapters)
    }

    /// Where phone-made transcripts wait for their retry, one file per episode key (a hex hash).
    nonisolated private static var keptFolder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "SpokenMargins/CommunityMapUploads", directoryHint: .isDirectory)
    }

    nonisolated private static func keptTranscript(episodeKey: String) -> TranscriptTimeline? {
        guard let url = keptFolder?.appending(path: "\(episodeKey).json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptTimeline.self, from: data)
    }

    /// Saves the transcript for a retry, or with nil removes it. Says whether it was saved.
    @discardableResult
    nonisolated private static func keep(_ timeline: TranscriptTimeline?, episodeKey: String) -> Bool {
        guard let url = keptFolder?.appending(path: "\(episodeKey).json") else { return false }
        guard let timeline else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let data = try? JSONEncoder().encode(timeline) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    /// The downloaded audio's length, for an episode whose feed doesn't give one.
    nonisolated static func measuredDurationMs(_ file: URL) async -> Int? {
        guard FileManager.default.isReadableFile(atPath: file.path),
              let duration = try? await AVURLAsset(url: file).load(.duration),
              duration.isNumeric, duration.seconds > 0 else { return nil }
        return Int((duration.seconds * 1_000).rounded())
    }

    /// Whether the audio file carries chapters, or nil when it couldn't be read (gone, or still
    /// being replaced), so a failed read holds the upload instead of counting as "no chapters".
    nonisolated static func hasEmbeddedChapters(_ file: URL) async -> Bool? {
        guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        let asset = AVURLAsset(url: file)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages
        ) else { return nil }
        return !groups.isEmpty
    }
}
