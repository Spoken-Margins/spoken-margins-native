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
        /// Offline, busy, rate-limited, switched off, at the spend cap, or the audio file wasn't
        /// there to check for embedded chapters. Retried after a day.
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
    case unverifiedFeed = "unverified_feed"
    case noEpisodeKey = "no_episode_key"
    case partialTranscript = "partial_transcript"
    case untimedTranscript = "untimed_transcript"
    case unknownDuration = "unknown_duration"
    case publisherChapters = "publisher_chapters"
    case alreadyUploaded = "already_uploaded"
    case rejectedBefore = "rejected_before"
    case retryTooSoon = "retry_too_soon"
    case tooManyAttempts = "too_many_attempts"
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
    /// A week of daily tries, then the episode is left alone (for example one that is only
    /// ever streamed, so its audio file is never there to check for embedded chapters).
    public static let maximumAttempts = 7
    /// A real timed transcript has at least one spoken segment per two minutes and no silent
    /// stretch longer than five; a publisher transcript stored as one block of text has neither.
    static let maximumSegmentSpacingMs = 120_000
    static let maximumGapMs = 300_000
    /// Pauses between words and sentences this short are part of a transcribed stretch; longer
    /// silences count against coverage.
    static let coveredPauseMs = 15_000

    /// Every rule from #552 that the phone can check on its own: consent first, then what the
    /// episode is, then whether this transcript is worth sending. The owner's switch is read
    /// afterwards by `CommunityMapUploader`, so a phone asks for the server config only when it
    /// has something to send.
    public static func decide(
        optedIn: Bool,
        item: Item,
        timeline: TranscriptTimeline,
        hasPublisherChapters: Bool,
        previous: CommunityMapUploadRecord?,
        audioDurationMs: Int? = nil,
        now: Date
    ) -> CommunityMapUploadDecision {
        guard optedIn else { return .skip(.optedOut) }
        guard isPodcastEpisode(item) else { return .skip(.notPodcastEpisode) }
        guard linksArePublic(item) else { return .skip(.privateLink) }
        guard feedIsVerified(item) else { return .skip(.unverifiedFeed) }
        guard let episodeKey = CommunityMapEpisodeKey.key(for: item) else { return .skip(.noEpisodeKey) }
        if let previous {
            switch previous.state {
            case .uploaded: return .skip(.alreadyUploaded)
            // Closed because of what one transcript was like: a better one (made on the phone
            // after a publisher's untimed one) may still upload.
            case .rejected where closedForTranscript(previous): break
            case .rejected: return .skip(.rejectedBefore)
            case .failed:
                guard now.timeIntervalSince(previous.lastAttemptAt) >= retryInterval else { return .skip(.retryTooSoon) }
                guard previous.attempts < maximumAttempts else { return .skip(.tooManyAttempts) }
            }
        }
        guard let durationMs = durationMs(item: item, audioDurationMs: audioDurationMs) else { return .skip(.unknownDuration) }
        guard hasRealTiming(timeline, durationMs: durationMs) else { return .skip(.untimedTranscript) }
        guard coverage(of: timeline, durationMs: durationMs) >= minimumCoverage else {
            return .skip(.partialTranscript)
        }
        guard !hasPublisherChapters else { return .skip(.publisherChapters) }
        return .upload(episodeKey: episodeKey)
    }

    static func closedForTranscript(_ record: CommunityMapUploadRecord) -> Bool {
        [CommunityMapUploadSkipReason.untimedTranscript, .partialTranscript, .unusableTranscript].contains {
            record.lastOutcome == CommunityMapUploadOutcome.skipped($0).diagnostic
        }
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

    /// The episode's feed must be known, not just its audio link: a private feed can serve its
    /// audio from a public-looking address. Items added from a followed show or a feed link
    /// store the feed as `sourceURL`; ones without it never upload.
    public static func feedIsVerified(_ item: Item) -> Bool {
        guard let feed = item.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), !feed.isEmpty else { return false }
        return ShareableLinkPolicy.shareableLink(feed) != nil
    }

    /// Whether publisher chapters are stored for the item, as a map from
    /// `attachPublisherChapters` or as chapters in its timeline.
    public static func hasPublisherChapters(map: ListeningMap?, timeline: TranscriptTimeline?) -> Bool {
        if let map, map.id.contains("-publisher-") { return true }
        return timeline?.chapters.contains { $0.id.hasPrefix("ch-publisher-") } ?? false
    }

    /// The episode's own length, from the feed or playback, or else measured from the downloaded
    /// audio. Not the transcript's: a transcript that stops early would measure itself as complete.
    public static func durationMs(item: Item, audioDurationMs: Int? = nil) -> Int? {
        item.media?.durationMs.flatMap { $0 > 0 ? $0 : nil } ?? audioDurationMs.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Failed uploads whose day has passed, for the app to try again (at most once a day).
    public static func dueForRetry(_ records: [CommunityMapUploadRecord], now: Date) -> [CommunityMapUploadRecord] {
        records.filter { $0.state == .failed && now.timeIntervalSince($0.lastAttemptAt) >= retryInterval }
            .sorted { $0.lastAttemptAt < $1.lastAttemptAt }
    }

    /// Readies a failed record for its retry, and says whether to try its item again. The record
    /// is closed instead when its item or transcript is gone, or the episode no longer has a key.
    /// When the episode's key has changed (a reimport filled in its GUID), its attempts move to
    /// the new key, unless that key already has a record, and the old row is closed. Either way
    /// the record can't stay due on every launch and crowd other episodes out of the retry batch.
    public static func prepareRetry(
        _ record: CommunityMapUploadRecord,
        item: Item?,
        hasTranscript: Bool,
        repository: CommunityMapUploadRepository,
        now: Date
    ) -> Bool {
        guard let item, hasTranscript, let key = CommunityMapEpisodeKey.key(for: item) else {
            close(record, reason: "item_gone", repository: repository, now: now)
            return false
        }
        guard key != record.id else { return true }
        do {
            if try repository.loadCommunityMapUpload(episodeKey: key) == nil {
                var moved = record
                moved.id = key
                try repository.saveCommunityMapUpload(moved)
            }
        } catch {
            // Storage failed: leave the old row for the next retry to move.
            return true
        }
        close(record, reason: "key_changed", repository: repository, now: now)
        return true
    }

    private static func close(_ record: CommunityMapUploadRecord, reason: String, repository: CommunityMapUploadRepository, now: Date) {
        var closed = record
        closed.state = .rejected
        closed.lastAttemptAt = now
        closed.lastOutcome = "skipped:\(reason)"
        try? repository.saveCommunityMapUpload(closed)
    }

    /// Whether the transcript's times come from listening, not from one block of text spread over
    /// the episode. The server keeps the first map made for an episode, so an untimed upload would
    /// decide the map every other phone sees.
    /// Segments sharing a start count once, as the request body joins them: a JSON transcript
    /// whose entries carry no times puts every entry at 0 running to the end.
    static func hasRealTiming(_ timeline: TranscriptTimeline, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs > 0 else { return false }
        var spoken: [(start: Int, end: Int)] = []
        for segment in timeline.segments.sorted(by: { $0.startMs < $1.startMs })
        where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = spoken.last, last.start == segment.startMs {
                spoken[spoken.count - 1].end = max(last.end, segment.endMs)
            } else {
                spoken.append((segment.startMs, segment.endMs))
            }
        }
        guard spoken.count >= max(2, durationMs / maximumSegmentSpacingMs) else { return false }
        var reached = spoken[0].end
        for segment in spoken.dropFirst() {
            if segment.start - reached > maximumGapMs { return false }
            reached = max(reached, segment.end)
        }
        return true
    }

    /// The share of the episode the spoken segments actually cover: the union of their spans,
    /// clipped to the episode, with pauses up to `coveredPauseMs` between them (and at either
    /// end) counted as covered, since a transcriber times words, not the silence between them.
    /// A longer stretch with no segments counts as missing.
    static func coverage(of timeline: TranscriptTimeline, durationMs: Int?) -> Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        let spans = timeline.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (start: min(max($0.startMs, 0), durationMs), end: min(max($0.endMs, 0), durationMs)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !spans.isEmpty else { return 0 }
        var missing = 0
        var reached = 0
        for span in spans where span.end > reached {
            if span.start - reached > coveredPauseMs { missing += span.start - reached }
            reached = span.end
        }
        if durationMs - reached > coveredPauseMs { missing += durationMs - reached }
        return Double(durationMs - missing) / Double(durationMs)
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

    /// Builds a body the server accepts, or nil when the transcript can't make one. Links are
    /// removed from the text, segments are sorted, ones sharing a start are joined so starts
    /// strictly increase, and long transcripts are merged into at most `maximumSegments` runs.
    public static func make(episodeKey: String, durationMs: Int, language: String, timeline: TranscriptTimeline) -> Self? {
        guard durationMs > 0, durationMs <= maximumDurationMs else { return nil }
        var segments: [Segment] = []
        for source in timeline.segments.sorted(by: { $0.startMs < $1.startMs }) {
            let text = withoutLinks(source.text)
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

    /// A publisher's transcript can read "visit https://example.com/promo"; the body carries no
    /// URL of any kind, so web addresses are cut out of the text and the spaces around them
    /// closed up: anything with a scheme (`https://`, `tel:`, `spotify:episode:…`: a word of two
    /// or more letters, then a colon with no space after it), `//` or
    /// `www.`, email addresses, IPv4 addresses with any port or path, and any run of dotted
    /// words with no space after a dot whose last part has two or more letters, in any script ("example.ai",
    /// "shop.example.co.uk", "example.net/deal", "例子.中国/优惠"). Abbreviations whose parts
    /// are single letters ("e.g.", "U.S.", "Ph.D."), numbers and times ("3.30", "2.5", "10:30")
    /// and a colon before a space ("Note: done") are kept.
    static func withoutLinks(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = linkPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:[a-z][a-z0-9+.-]*://|www\.|[a-z][a-z0-9+.-]+:)\S+|(?<![\w:/.])//\S+|\b\d{1,3}(?:\.\d{1,3}){3}\b(?::\d+)?(?:/\S*)?|\S+@(?:[\p{L}\p{N}-]+\.)+\p{L}{2,}\S*|\b(?:[\p{L}\p{N}-]+\.)+\p{L}{2,}(?:/\S*|\b)"#
    )

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
    public static let transcriptsURL = ProductServer.url(path: "/api/v1/maps/transcripts")

    private let url: URL
    private let post: CommunityMapUploadPost

    public init(url: URL = Self.transcriptsURL, post: @escaping CommunityMapUploadPost) {
        self.url = url
        self.post = post
    }

    /// Uploads the transcript once if every rule allows it, and records the attempt. Never
    /// throws: failures are recorded and shown in diagnostics.
    ///
    /// - `optedIn` is read first and again just before the body is sent, so turning the setting
    ///   off while the server config loads still stops the upload.
    /// - `publisherChapters` answers whether the publisher has chapters, or nil when that can't be
    ///   checked yet (the audio file isn't on the phone to read embedded chapters from).
    /// - `mapsState` is read only for an otherwise eligible episode, so an opted-out phone, or one
    ///   with nothing to send, makes no request at all.
    ///
    /// An eligible episode held back by something that can change (no file to check, length not
    /// yet known, maps off, no config, the app closed mid-upload) is recorded as failed, so the
    /// app tries it again a day later.
    public func uploadIfEligible(
        item: Item,
        timeline: TranscriptTimeline,
        language: String,
        repository: CommunityMapUploadRepository,
        now: Date = Date(),
        optedIn: @Sendable () async -> Bool,
        publisherChapters: @Sendable () async -> Bool?,
        audioDurationMs: @Sendable () async -> Int? = { nil },
        mapsState: @Sendable () async -> ServerFeatureState
    ) async -> CommunityMapUploadOutcome {
        guard await optedIn() else { return .skipped(.optedOut) }
        let previous = CommunityMapEpisodeKey.key(for: item).flatMap { try? repository.loadCommunityMapUpload(episodeKey: $0) }
        let chapters = await publisherChapters()
        // A feed can omit the length; the downloaded audio is measured then.
        let measured = CommunityMapUploadPolicy.durationMs(item: item) == nil ? await audioDurationMs() : nil
        // Reading the audio file can take a while; the setting may have been turned off meanwhile.
        guard await optedIn() else { return .skipped(.optedOut) }
        let decision = CommunityMapUploadPolicy.decide(
            optedIn: true, item: item, timeline: timeline,
            hasPublisherChapters: chapters ?? false, previous: previous, audioDurationMs: measured, now: now
        )
        guard case .upload(let episodeKey) = decision else {
            let reason: CommunityMapUploadSkipReason
            if case .skip(let skipped) = decision { reason = skipped } else { reason = .unusableTranscript }
            // The episode's length can be learned later (from the feed or playback): try again.
            if reason == .unknownDuration, let episodeKey = CommunityMapEpisodeKey.key(for: item) {
                return save(.failed(reason.rawValue), episodeKey: episodeKey, item: item, previous: previous, now: now, repository: repository)
            }
            return settle(previous, skipped: reason, now: now, repository: repository)
        }
        guard let durationMs = CommunityMapUploadPolicy.durationMs(item: item, audioDurationMs: measured),
              let upload = CommunityMapTranscriptUpload.make(episodeKey: episodeKey, durationMs: durationMs, language: language, timeline: timeline),
              let body = try? upload.encoded() else {
            return settle(previous, skipped: .unusableTranscript, now: now, repository: repository)
        }
        guard chapters != nil else {
            return save(.failed("chapters_unchecked"), episodeKey: episodeKey, item: item, previous: previous, now: now, repository: repository)
        }
        // Recorded before any request, so an app that is closed mid-upload still retries it. If
        // the attempt can't be recorded (storage full), nothing is sent: an unrecorded attempt
        // would let the next launch send again, past the once-a-day limit.
        guard (try? repository.saveCommunityMapUpload(record(.failed("interrupted"), episodeKey: episodeKey, item: item, previous: previous, now: now))) != nil else {
            return .failed("storage")
        }
        guard (await mapsState()).isOn else {
            return save(.failed(CommunityMapUploadSkipReason.mapsOff.rawValue), episodeKey: episodeKey, item: item, previous: previous, now: now, repository: repository)
        }
        guard await optedIn() else { return .skipped(.optedOut) }
        let outcome: CommunityMapUploadOutcome
        do {
            let status = try await post(url, body)
            switch status {
            case 200, 202: outcome = .uploaded(status: status)
            case 400..<500 where status != 429: outcome = .rejected(status: status)
            default: outcome = .failed(String(status))
            }
        } catch {
            outcome = .failed("network")
        }
        return save(outcome, episodeKey: episodeKey, item: item, previous: previous, now: now, repository: repository)
    }

    /// Records this attempt for the episode and returns its outcome.
    private func save(
        _ outcome: CommunityMapUploadOutcome,
        episodeKey: String,
        item: Item,
        previous: CommunityMapUploadRecord?,
        now: Date,
        repository: CommunityMapUploadRepository
    ) -> CommunityMapUploadOutcome {
        try? repository.saveCommunityMapUpload(record(outcome, episodeKey: episodeKey, item: item, previous: previous, now: now))
        return outcome
    }

    private func record(
        _ outcome: CommunityMapUploadOutcome,
        episodeKey: String,
        item: Item,
        previous: CommunityMapUploadRecord?,
        now: Date
    ) -> CommunityMapUploadRecord {
        let state: CommunityMapUploadRecord.State
        switch outcome {
        case .uploaded: state = .uploaded
        case .rejected: state = .rejected
        case .failed, .skipped: state = .failed
        }
        return CommunityMapUploadRecord(
            id: episodeKey, itemId: item.id, state: state, attempts: (previous?.attempts ?? 0) + 1,
            lastAttemptAt: now, lastOutcome: outcome.diagnostic
        )
    }

    /// A retry that finds the episode no longer qualifies (chapters found in the downloaded file,
    /// moved to the Trash, a week of tries used up) closes its record, so it stops coming back
    /// first in every retry and holding the others up.
    private func settle(
        _ previous: CommunityMapUploadRecord?,
        skipped reason: CommunityMapUploadSkipReason,
        now: Date,
        repository: CommunityMapUploadRepository
    ) -> CommunityMapUploadOutcome {
        if var record = previous, record.state == .failed, reason != .retryTooSoon {
            record.state = .rejected
            record.lastAttemptAt = now
            record.lastOutcome = CommunityMapUploadOutcome.skipped(reason).diagnostic
            try? repository.saveCommunityMapUpload(record)
        }
        return .skipped(reason)
    }
}
