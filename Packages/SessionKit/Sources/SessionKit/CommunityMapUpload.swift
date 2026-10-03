#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Community listening maps, phone side of the upload (#552). A listener who opts in sends the
// full transcript of a public podcast episode to the owner's server once. The server makes the
// map and deletes the transcript (#551, research/B4/server/internal/maps). This file decides
// whether to upload, builds the request body and remembers what was sent; the app only calls it
// after a transcript is attached.

/// The episode key both installs derive for the same episode, so a map made from one phone's
/// transcript is found by another (#553). It hashes the feed GUID, which is the same for every
/// subscriber, or, with no GUID, the enclosure's file identity with tracking redirects removed.
public enum CommunityMapEpisodeKey {
    static let prefix = "spokenmargins.episode.v1\n"

    public static func key(episodeGUID: String?, enclosureURL: String?) -> String? {
        if let guid = episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            return hash(prefix + guid)
        }
        // A distinct namespace, so an enclosure identity can't equal some feed's GUID.
        guard let file = PodcastEnclosureIdentity.key(enclosureURL) else { return nil }
        return hash(prefix + "enclosure:" + file)
    }

    public static func key(for item: Item) -> String? {
        key(episodeGUID: item.episodeGUID, enclosureURL: item.media?.url)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the app remembers about one episode's upload, kept as record kind
/// `community_map_upload`. Build 29 reads records by kind and never reads this one.
public struct CommunityMapUploadRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        /// The server took it (202) or already has a map (200). Never sent again.
        case uploaded
        /// Offline, busy, rate-limited, switched off or at the spend cap. Retried after a day.
        case failed
        /// The server refused the body (4xx other than 429). Sending it again won't help.
        case rejected
    }

    /// The episode key; one record per episode, whichever item it came from.
    public var id: String
    public var itemId: String
    public var state: State
    public var attempts: Int
    public var lastAttemptAt: Date
    /// The HTTP status, or a short reason such as `network`. Shown in diagnostics.
    public var lastOutcome: String

    public init(id: String, itemId: String, state: State, attempts: Int, lastAttemptAt: Date, lastOutcome: String) {
        self.id = id
        self.itemId = itemId
        self.state = state
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastOutcome = lastOutcome
    }
}

public protocol CommunityMapUploadRepository: Sendable {
    func saveCommunityMapUpload(_ record: CommunityMapUploadRecord) throws
    func loadCommunityMapUpload(episodeKey: String) throws -> CommunityMapUploadRecord?
    func loadCommunityMapUploads() throws -> [CommunityMapUploadRecord]
}

public enum CommunityMapUploadSkipReason: String, Equatable, Sendable {
    case optedOut = "opted_out"
    case mapsOff = "maps_off"
    case notPodcastEpisode = "not_podcast_episode"
    case privateLink = "private_link"
    case noEpisodeKey = "no_episode_key"
    case partialTranscript = "partial_transcript"
    case untimedTranscript = "untimed_transcript"
    case publisherChapters = "publisher_chapters"
    case alreadyUploaded = "already_uploaded"
    case rejectedBefore = "rejected_before"
    case retryTooSoon = "retry_too_soon"
    case unusableTranscript = "unusable_transcript"
}

public enum CommunityMapUploadDecision: Equatable, Sendable {
    case upload(episodeKey: String)
    case skip(CommunityMapUploadSkipReason)
}

public enum CommunityMapUploadPolicy {
    /// A transcript made for one Margin covers a window, not the episode.
    public static let minimumCoverage = 0.95
    /// At most one retry a day after a failure.
    public static let retryInterval: TimeInterval = 24 * 60 * 60
    /// A real timed transcript has at least one spoken segment per two minutes and no silent
    /// stretch longer than five; a publisher transcript stored as one block of text has neither.
    static let minimumDurationMs = 60_000
    static let maximumSegmentSpacingMs = 120_000
    static let maximumGapMs = 300_000

    /// Every rule from #552, in the order a listener would care about: consent first, then the
    /// owner's switch, then what the episode is, then whether this transcript is worth sending.
    public static func decide(
        optedIn: Bool,
        mapsState: ServerFeatureState,
        item: Item,
        timeline: TranscriptTimeline,
        hasPublisherChapters: Bool,
        previous: CommunityMapUploadRecord?,
        now: Date
    ) -> CommunityMapUploadDecision {
        guard optedIn else { return .skip(.optedOut) }
        guard mapsState.isOn else { return .skip(.mapsOff) }
        guard isPodcastEpisode(item) else { return .skip(.notPodcastEpisode) }
        guard linksArePublic(item) else { return .skip(.privateLink) }
        guard let episodeKey = CommunityMapEpisodeKey.key(for: item) else { return .skip(.noEpisodeKey) }
        let durationMs = durationMs(item: item, timeline: timeline)
        guard hasRealTiming(timeline, durationMs: durationMs) else { return .skip(.untimedTranscript) }
        guard coverage(of: timeline, durationMs: durationMs) >= minimumCoverage else {
            return .skip(.partialTranscript)
        }
        guard !hasPublisherChapters else { return .skip(.publisherChapters) }
        if let previous {
            switch previous.state {
            case .uploaded: return .skip(.alreadyUploaded)
            case .rejected: return .skip(.rejectedBefore)
            case .failed:
                guard now.timeIntervalSince(previous.lastAttemptAt) >= retryInterval else { return .skip(.retryTooSoon) }
            }
        }
        return .upload(episodeKey: episodeKey)
    }

    /// An episode streamed or downloaded from a podcast feed: remote audio over http(s) in an item
    /// that came from a feed or carries a feed GUID.
    public static func isPodcastEpisode(_ item: Item) -> Bool {
        guard item.deletedAt == nil, item.mediaType == TargetType.transcriptBackedMedia.rawValue,
              let media = item.media, media.sourceType == .remoteStream,
              let scheme = media.url.flatMap(URL.init(string:))?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return false }
        return item.sourceURL != nil || item.episodeGUID != nil
    }

    /// The feed URL, the enclosure and the link the listener added must all be shareable, so a
    /// private feed never uploads even though the request body carries none of them.
    public static func linksArePublic(_ item: Item) -> Bool {
        let links = [item.media?.url, item.sourceURL, item.externalReference].compactMap { $0 }
        return links.allSatisfy { ShareableLinkPolicy.shareableLink($0) != nil }
    }

    /// Whether publisher chapters are stored for the item, as a map from
    /// `attachPublisherChapters` or as chapters in its timeline.
    public static func hasPublisherChapters(map: ListeningMap?, timeline: TranscriptTimeline?) -> Bool {
        if let map, map.id.contains("-publisher-") { return true }
        return timeline?.chapters.contains { $0.id.hasPrefix("ch-publisher-") } ?? false
    }

    public static func durationMs(item: Item, timeline: TranscriptTimeline) -> Int? {
        [item.media?.durationMs, timeline.durationMs].compactMap { $0 }.first { $0 > 0 }
    }

    /// Failed uploads whose day has passed, for the app to try again (at most once a day).
    public static func dueForRetry(_ records: [CommunityMapUploadRecord], now: Date) -> [CommunityMapUploadRecord] {
        records.filter { $0.state == .failed && now.timeIntervalSince($0.lastAttemptAt) >= retryInterval }
            .sorted { $0.lastAttemptAt < $1.lastAttemptAt }
    }

    /// Whether the transcript's times come from listening, not from one block of text spread over
    /// the episode. The server keeps the first map made for an episode, so an untimed upload would
    /// decide the map every other phone sees.
    static func hasRealTiming(_ timeline: TranscriptTimeline, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs >= minimumDurationMs else { return false }
        let spoken = timeline.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startMs < $1.startMs }
        guard spoken.count >= max(2, durationMs / maximumSegmentSpacingMs) else { return false }
        var reached = spoken[0].endMs
        for segment in spoken.dropFirst() {
            if segment.startMs - reached > maximumGapMs { return false }
            reached = max(reached, segment.endMs)
        }
        return true
    }

    /// The share of the episode between the first spoken segment and the last.
    static func coverage(of timeline: TranscriptTimeline, durationMs: Int?) -> Double {
        let spoken = timeline.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let durationMs, durationMs > 0,
              let first = spoken.map(\.startMs).min(), let last = spoken.map(\.endMs).max(), last > first else { return 0 }
        return Double(min(last, durationMs) - max(first, 0)) / Double(durationMs)
    }
}

/// The request body for `POST /api/v1/maps/transcripts`, schema
/// `spokenmargins.episode-transcript.v1`. It holds only the episode key, the duration, the
/// language and timed text; no URL, title, Margin or path of any kind.
public struct CommunityMapTranscriptUpload: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.episode-transcript.v1"
    /// The server's limits (research/B4/server/internal/maps/transcript.go).
    public static let maximumBytes = 2 << 20
    public static let maximumSegments = 3_000
    static let maximumDurationMs = 48 * 3_600 * 1_000

    public struct Segment: Codable, Equatable, Sendable {
        public var id: String
        public var startMs: Int
        public var endMs: Int
        public var text: String
    }

    public var schema: String
    public var episodeKey: String
    public var durationMs: Int
    public var language: String
    public var segments: [Segment]

    /// Builds a body the server accepts, or nil when the transcript can't make one. Segments
    /// are sorted, ones sharing a start are joined so starts strictly increase, and long
    /// transcripts are merged into at most `maximumSegments` runs.
    public static func make(episodeKey: String, durationMs: Int, language: String, timeline: TranscriptTimeline) -> Self? {
        guard durationMs > 0, durationMs <= maximumDurationMs else { return nil }
        var segments: [Segment] = []
        for source in timeline.segments.sorted(by: { $0.startMs < $1.startMs }) {
            let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = min(max(0, source.startMs), durationMs)
            let end = min(max(start, source.endMs), maximumDurationMs)
            if let last = segments.last, last.startMs == start {
                segments[segments.count - 1].text += " " + text
                segments[segments.count - 1].endMs = max(last.endMs, end)
            } else {
                segments.append(Segment(id: "", startMs: start, endMs: end, text: text))
            }
        }
        guard !segments.isEmpty else { return nil }
        if segments.count > maximumSegments {
            let size = (segments.count + maximumSegments - 1) / maximumSegments
            segments = stride(from: 0, to: segments.count, by: size).map { index in
                let run = segments[index..<min(index + size, segments.count)]
                return Segment(id: "", startMs: run.first!.startMs, endMs: run.map(\.endMs).max()!,
                               text: run.map(\.text).joined(separator: " "))
            }
        }
        for index in segments.indices { segments[index].id = "s\(index + 1)" }
        let upload = Self(schema: schema, episodeKey: episodeKey, durationMs: durationMs,
                          language: normalizedLanguage(language), segments: segments)
        guard let body = try? upload.encoded(), body.count <= maximumBytes else { return nil }
        return upload
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// A BCP 47 language tag the server accepts (`^[A-Za-z0-9-]{1,35}$`), or `und`.
    static func normalizedLanguage(_ value: String) -> String {
        let tag = value.replacingOccurrences(of: "_", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (1...35).contains(tag.count), tag.unicodeScalars.allSatisfy(allowed.contains) else { return "und" }
        return tag
    }
}

public enum CommunityMapUploadOutcome: Equatable, Sendable {
    case skipped(CommunityMapUploadSkipReason)
    case uploaded(status: Int)
    case failed(String)
    case rejected(status: Int)

    /// One line for Diagnostics. Never holds the episode key or any URL.
    public var diagnostic: String {
        switch self {
        case .skipped(let reason): "skipped:\(reason.rawValue)"
        case .uploaded(let status): "uploaded:\(status)"
        case .failed(let reason): "failed:\(reason)"
        case .rejected(let status): "rejected:\(status)"
        }
    }
}

/// Sends one transcript body and returns the HTTP status.
public typealias CommunityMapUploadPost = @Sendable (_ url: URL, _ body: Data) async throws -> Int

public struct CommunityMapUploader: Sendable {
    public static let transcriptsURL = URL(string: "https://spokenmargins.proximitytoprogress.com/api/v1/maps/transcripts")!

    private let url: URL
    private let post: CommunityMapUploadPost

    public init(url: URL = Self.transcriptsURL, post: @escaping CommunityMapUploadPost) {
        self.url = url
        self.post = post
    }

    /// Uploads the transcript once if every rule allows it, and records the attempt. The server
    /// switch is read only after the listener has opted in, so an opted-out phone sends nothing,
    /// not even a config request. Never throws: failures are recorded and shown in diagnostics.
    public func uploadIfEligible(
        item: Item,
        timeline: TranscriptTimeline,
        hasPublisherChapters: Bool,
        optedIn: Bool,
        language: String,
        repository: CommunityMapUploadRepository,
        now: Date = Date(),
        mapsState: @Sendable () async -> ServerFeatureState
    ) async -> CommunityMapUploadOutcome {
        guard optedIn else { return .skipped(.optedOut) }
        let serverState = await mapsState()
        let previous = CommunityMapEpisodeKey.key(for: item).flatMap { try? repository.loadCommunityMapUpload(episodeKey: $0) }
        let decision = CommunityMapUploadPolicy.decide(
            optedIn: optedIn, mapsState: serverState, item: item, timeline: timeline,
            hasPublisherChapters: hasPublisherChapters, previous: previous, now: now
        )
        guard case .upload(let episodeKey) = decision else {
            if case .skip(let reason) = decision { return .skipped(reason) }
            return .skipped(.unusableTranscript)
        }
        guard let durationMs = CommunityMapUploadPolicy.durationMs(item: item, timeline: timeline),
              let upload = CommunityMapTranscriptUpload.make(episodeKey: episodeKey, durationMs: durationMs, language: language, timeline: timeline),
              let body = try? upload.encoded() else {
            return .skipped(.unusableTranscript)
        }
        let outcome: CommunityMapUploadOutcome
        let recordState: CommunityMapUploadRecord.State
        do {
            let status = try await post(url, body)
            switch status {
            case 200, 202:
                (outcome, recordState) = (.uploaded(status: status), .uploaded)
            case 400..<500 where status != 429:
                (outcome, recordState) = (.rejected(status: status), .rejected)
            default:
                (outcome, recordState) = (.failed(String(status)), .failed)
            }
        } catch {
            (outcome, recordState) = (.failed("network"), .failed)
        }
        let record = CommunityMapUploadRecord(
            id: episodeKey, itemId: item.id, state: recordState, attempts: (previous?.attempts ?? 0) + 1,
            lastAttemptAt: now, lastOutcome: outcome.diagnostic
        )
        try? repository.saveCommunityMapUpload(record)
        return outcome
    }
}
