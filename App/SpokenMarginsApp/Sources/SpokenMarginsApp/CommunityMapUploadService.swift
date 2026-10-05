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
            if let folder = Self.keptFolder { try? FileManager.default.removeItem(at: folder) }
            return
        }
        guard let records = try? store.loadCommunityMapUploads() else { return }
        for record in CommunityMapUploadPolicy.dueForRetry(records, now: Date()).prefix(3) {
            let item = try? store.loadItem(id: record.itemId)
            let kept = Self.keptTranscript(episodeKey: record.id)
            // Closes records whose item is gone and moves ones whose episode key has changed,
            // so they stop coming back first in every retry.
            guard CommunityMapUploadPolicy.prepareRetry(
                record, item: item,
                hasTranscript: kept != nil || (try? store.loadTranscriptTimeline(itemId: record.itemId)) != nil,
                repository: store, now: Date()
            ) else {
                Self.keep(nil, episodeKey: record.id)
                continue
            }
            if let kept, let key = item.flatMap(CommunityMapEpisodeKey.key(for:)), key != record.id {
                Self.keep(kept, episodeKey: key)
                Self.keep(nil, episodeKey: record.id)
            }
            attempt(itemId: record.itemId, store: store, localAudio: localAudio, report: report)
        }
    }

    private static var optedIn: Bool { UserDefaults.standard.bool(forKey: optInKey) }

    private func attempt(
        itemId: String,
        transcribed: TranscriptTimeline? = nil,
        store: SQLiteSessionStore,
        localAudio: @escaping @MainActor (String) -> URL?,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard let item = try? store.loadItem(id: itemId),
              let episodeKey = CommunityMapEpisodeKey.key(for: item) else { return }
        guard !inFlight.contains(episodeKey) else {
            if let transcribed { queued[episodeKey] = (itemId, transcribed) }
            return
        }
        // A transcript the phone made for the map comes first: a stored one may be a publisher's
        // that could not upload.
        let stored = try? store.loadTranscriptTimeline(itemId: itemId)?.timeline
        guard let timeline = transcribed ?? Self.keptTranscript(episodeKey: episodeKey) ?? stored else { return }
        let storedChapters = CommunityMapUploadPolicy.hasPublisherChapters(
            map: try? store.loadListeningMap(itemId: itemId), timeline: timeline
        ) || CommunityMapUploadPolicy.hasPublisherChapters(map: nil, timeline: stored)
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
            // Keep the phone's transcript only while its upload waits to be tried again.
            let waiting = (try? store.loadCommunityMapUpload(episodeKey: episodeKey))?.state == .failed
            if transcribed != nil || !waiting { Self.keep(waiting ? timeline : nil, episodeKey: episodeKey) }
            report(outcome.diagnostic)
            if let next = self.queued.removeValue(forKey: episodeKey) {
                self.attempt(itemId: next.itemId, transcribed: next.timeline, store: store, localAudio: localAudio, report: report)
            }
        }
    }

    /// Where phone-made transcripts wait for their retry, one file per episode key (a hex hash).
    private static var keptFolder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "SpokenMargins/CommunityMapUploads", directoryHint: .isDirectory)
    }

    private static func keptTranscript(episodeKey: String) -> TranscriptTimeline? {
        guard let url = keptFolder?.appending(path: "\(episodeKey).json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptTimeline.self, from: data)
    }

    /// Saves the transcript for a retry, or with nil removes it.
    private static func keep(_ timeline: TranscriptTimeline?, episodeKey: String) {
        guard let url = keptFolder?.appending(path: "\(episodeKey).json") else { return }
        guard let timeline, let data = try? JSONEncoder().encode(timeline) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
