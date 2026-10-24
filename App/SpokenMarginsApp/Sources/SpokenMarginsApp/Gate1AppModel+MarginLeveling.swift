import Foundation
import SessionKit
import SessionKitAudio

/// Spoken Margins play from a leveled copy, so a whisper plays about as loud as the episode around it
/// and a loud one is turned down (#467). The recording is never changed; the copy lives in the Caches
/// folder and is made once per recording (`LeveledMarginCache`, built on #465).
extension Gate1AppModel {
    static let leveledMargins = LeveledMarginCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LeveledMargins", isDirectory: true)
    )

    /// Recordings already handed to the cache this launch.
    private static var requestedLeveling = Set<String>()

    /// What to play for a Margin's recording: its leveled copy when it is ready, otherwise the
    /// recording itself, and the copy is made for the next play. `anchorMediaTimeMs` is where the
    /// Margin sits in `itemId`, which sets the target when that item is a podcast on the device.
    func leveledMarginURL(_ recording: URL, itemId: String?, anchorMediaTimeMs: Int?) -> URL {
        // Never reads the recording: this runs on the main thread when a Margin plays (#2510).
        if let copy = Self.leveledMargins.knownCopy(for: recording) {
            diagnostics["marginLeveling"] = "leveled"
            return copy
        }
        diagnostics["marginLeveling"] = "original:not_ready"
        prepareLeveledMargin(recording, itemId: itemId, anchorMediaTimeMs: anchorMediaTimeMs)
        return recording
    }

    /// The episode's file on this device: the one the listener downloaded, or the one they brought for a
    /// shared podcast.
    private func localEpisodeFile(for itemId: String) -> URL? {
        importedPodcastRecipientLocalURLs[itemId] ?? podcastDownloadCoordinator?.validatedLocalURL(for: itemId)
    }

    /// Makes the leveled copy in the background, so it is ready by the time the Margin plays.
    func prepareLeveledMargin(_ recording: URL, itemId: String?, anchorMediaTimeMs: Int?) {
        var window: LeveledMarginCache.SourceWindow?
        if let itemId, let anchorMediaTimeMs, let file = localEpisodeFile(for: itemId) {
            window = .init(file: file, anchorMediaTimeMs: anchorMediaTimeMs)
        }
        let sourceWindow = window
        Task { [weak self] in
            let outcome = await Self.leveledMargins.level(recording, sourceWindow: sourceWindow)
            self?.diagnostics["marginLeveling"] = outcome.diagnosticValue
        }
    }

    /// The voice lookup for a Margin moment (#159): each Margin plays its leveled copy once it is ready,
    /// and every copy that isn't is started now, so the later Margins of the moment are usually ready by
    /// the time playback reaches them.
    func leveledVoiceURL(_ voiceURLs: [String: URL], itemId: String, margins: [MarginMomentAnchor]) -> (String) -> URL? {
        let anchors = Dictionary(margins.map { ($0.marginId, $0.mediaTimeMs) }, uniquingKeysWith: { first, _ in first })
        for (id, url) in voiceURLs where Self.leveledMargins.knownCopy(for: url) == nil {
            prepareLeveledMargin(url, itemId: itemId, anchorMediaTimeMs: anchors[id])
        }
        return { [weak self] id in
            guard let url = voiceURLs[id] else { return nil }
            return self?.leveledMarginURL(url, itemId: itemId, anchorMediaTimeMs: anchors[id]) ?? url
        }
    }

    /// Starts the leveled copies of the open item's spoken Margins, its own and shared ones, when the item is
    /// opened or gains a Margin, so the first play is usually already leveled. Each recording is handed over
    /// once per launch (twice if the episode arrives meanwhile); a copy that has gone is made again when the Margin is played.
    func prepareLeveledMargins(from previous: ItemDetailState) {
        let detail = selectedItem
        func count(_ item: ItemDetailState) -> Int {
            item.interjections.count + item.importedCommentaryInterjections.values.reduce(0) { $0 + $1.count }
        }
        guard !detail.id.isEmpty, previous.id != detail.id || count(previous) != count(detail) else { return }
        var recordings: [(url: URL, anchorMediaTimeMs: Int?)] = []
        for margin in detail.interjections where margin.captureKind != .written {
            guard let path = margin.audioPath, let url = resolvedInterjectionAudioURL(for: path) else { continue }
            recordings.append((url, margin.anchor.mediaTimeMs))
        }
        for margin in detail.importedCommentaryInterjections.values.joined() {
            guard let path = margin.audioPath, let url = resolvedApplicationSupportAssetURL(for: path) else { continue }
            recordings.append((url, margin.resolution.localMediaTimeMs))
        }
        // Handed over again once the episode is on the device, because a copy made without it is replaced.
        let hasEpisode = localEpisodeFile(for: detail.id) != nil
        for recording in recordings where Self.requestedLeveling.insert("\(recording.url.path)|\(hasEpisode)").inserted {
            prepareLeveledMargin(recording.url, itemId: detail.id, anchorMediaTimeMs: recording.anchorMediaTimeMs)
        }
    }
}

