import Foundation

// Community listening maps, phone side of the fetch (#553). A podcast episode with no chapters
// and no map of its own asks the owner's server for a map another listener's transcript made
// (#551, uploaded by #552). This file decides whether to ask, reads the answer and turns it into
// the same proposal and projection an on-device map has, so Skim and the item page need nothing
// new. The app calls `CommunityMapFetcher` when an episode opens and renders the Skim summaries.

/// The server's map for one episode, `GET /api/v1/maps/<episodeKey>`
/// (schema `spokenmargins.episode-map.v1`, research/B4/server/internal/maps/transcript.go).
public struct CommunityMapResponse: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.episode-map.v1"

    public struct Scene: Codable, Equatable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var title: String
        public var summary: String

        public init(startMs: Int, endMs: Int, title: String, summary: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.title = title
            self.summary = summary
        }
    }

    public var schema: String
    public var episodeKey: String
    public var durationMs: Int
    public var generator: String
    public var createdAt: String
    public var scenes: [Scene]

    public init(schema: String = CommunityMapResponse.schema, episodeKey: String, durationMs: Int, generator: String, createdAt: String, scenes: [Scene]) {
        self.schema = schema
        self.episodeKey = episodeKey
        self.durationMs = durationMs
        self.generator = generator
        self.createdAt = createdAt
        self.scenes = scenes
    }
}

public enum CommunityMapFetchSkipReason: String, Equatable, Sendable {
    /// The listener hasn't turned on community map lookups (the default).
    case optedOut = "opted_out"
    case notPodcastEpisode = "not_podcast_episode"
    case privateLink = "private_link"
    case unverifiedFeed = "unverified_feed"
    case noEpisodeKey = "no_episode_key"
    case publisherChapters = "publisher_chapters"
    case hasMap = "has_map"
    case unknownDuration = "unknown_duration"
    case checkedRecently = "checked_recently"
}

public enum CommunityMapFetchDecision: Equatable, Sendable {
    case fetch(episodeKey: String)
    case skip(CommunityMapFetchSkipReason)
}

/// What the phone already holds for an episode. Read again just before a fetched map is stored,
/// so chapters or a map that arrive while the request is out are never replaced.
public struct CommunityMapLocalState: Equatable, Sendable {
    /// The publisher's chapters, from the feed or the audio file.
    public var hasPublisherChapters: Bool
    /// Any map of the listener's own, a friend's, or one made on the phone.
    public var hasMap: Bool

    public init(hasPublisherChapters: Bool, hasMap: Bool) {
        self.hasPublisherChapters = hasPublisherChapters
        self.hasMap = hasMap
    }

    /// What the store holds for the item. `hasEmbeddedChapters` is what the app read from the
    /// downloaded audio file, which the store can't tell. Any map counts, whoever made it: a
    /// proposal or projection (the listener's, a friend's or a community one), a friend's map
    /// that is imported but not placed yet, a stored listening
    /// map that isn't the publisher's, or chapters in the transcript timeline.
    ///
    /// Opening an episode asks this, so it reads ids and chapters, never a podcast's whole transcript or a map (#2506).
    public static func read(itemId: String, repository: SessionRepository, hasEmbeddedChapters: Bool = false) -> Self {
        let chapters = (try? repository.loadTranscriptTimelineChapters(itemId: itemId)) ?? []
        let listeningMapId = (try? repository.listeningMapId(itemId: itemId)) ?? nil
        let proposalIds = (try? repository.portableListeningMapProposalIds(itemId: itemId)) ?? []
        let projection = try? repository.loadResolvedListeningMapProjection(itemId: itemId)
        let friendsMap = ((try? repository.loadImportedCommentaryLayers(itemId: itemId)) ?? []).contains(where: \.holdsListeningMap)
        return Self(
            hasPublisherChapters: hasEmbeddedChapters
                || CommunityMapUploadPolicy.hasPublisherChapters(mapId: listeningMapId, chapters: chapters),
            hasMap: !proposalIds.isEmpty || projection != nil || listeningMapId != nil || friendsMap
                || !chapters.isEmpty
        )
    }
}

extension ImportedCommentaryLayer {
    /// A friend's shared Listening Map that hasn't been deleted. It gets a projection only once the
    /// episode's audio is on the phone, so until then it is the only trace of the map.
    public var holdsListeningMap: Bool { deletedAt == nil && listeningMapProposals?.isEmpty == false }
}

public enum CommunityMapFetchPolicy {
    /// An episode the server had no map for is asked again after this long, since another
    /// listener may have made one meanwhile.
    public static let recheckInterval: TimeInterval = 6 * 60 * 60
    /// An episode the server couldn't be reached about (offline, busy, a timeout) is asked again
    /// after this long, so coming back online soon after finds its map.
    public static let failureRetryInterval: TimeInterval = 5 * 60

    /// Every rule from #553 the phone can check on its own, in the order that asks least: consent
    /// (a lookup tells the server which episode the listener opened, and their IP address, so it
    /// is opt-in until requests go through an anonymous relay), the kind of episode, what it already has, then when it was last asked about. The server's
    /// `maps` switch is read afterwards by `CommunityMapFetcher`, so an episode that can't take a
    /// community map never causes a config request.
    ///
    /// The episode must be a public one, as for an upload (#552): a private feed's episodes never
    /// ask, though the key is a hash.
    public static func decide(
        optedIn: Bool,
        item: Item,
        local: CommunityMapLocalState,
        blockedUntil: Date?,
        audioDurationMs: Int? = nil,
        now: Date
    ) -> CommunityMapFetchDecision {
        guard optedIn else { return .skip(.optedOut) }
        guard CommunityMapUploadPolicy.isPodcastEpisode(item) else { return .skip(.notPodcastEpisode) }
        guard CommunityMapUploadPolicy.linksArePublic(item) else { return .skip(.privateLink) }
        guard CommunityMapUploadPolicy.feedIsVerified(item) else { return .skip(.unverifiedFeed) }
        guard let episodeKey = CommunityMapEpisodeKey.key(for: item) else { return .skip(.noEpisodeKey) }
        guard !local.hasPublisherChapters else { return .skip(.publisherChapters) }
        guard !local.hasMap else { return .skip(.hasMap) }
        // A map is only used for the edition it was made from, which is told by length.
        guard CommunityMapUploadPolicy.durationMs(item: item, audioDurationMs: audioDurationMs) != nil else {
            return .skip(.unknownDuration)
        }
        // A block longer than the longest one is a clock that was set back, not a real wait.
        if let blockedUntil, now < blockedUntil, blockedUntil.timeIntervalSince(now) <= recheckInterval {
            return .skip(.checkedRecently)
        }
        return .fetch(episodeKey: episodeKey)
    }
}

/// Until when each episode isn't asked about again, so opening an episode again doesn't ask
/// again. Pure: the app keeps the value (in `UserDefaults`) and passes it back. Episode keys are
/// hashes and no title, URL or item id is held.
public struct CommunityMapFetchLog: Codable, Equatable, Sendable {
    public static let maximumEntries = 200

    public private(set) var blockedUntil: [String: Date]

    public init(blockedUntil: [String: Date] = [:]) {
        self.blockedUntil = blockedUntil
    }

    public func blockedUntil(episodeKey: String) -> Date? { blockedUntil[episodeKey] }

    public mutating func block(episodeKey: String, until date: Date) {
        blockedUntil[episodeKey] = date
        guard blockedUntil.count > Self.maximumEntries else { return }
        // Earliest first out; the key breaks ties so the result doesn't depend on dictionary order.
        let earliest = blockedUntil.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .prefix(blockedUntil.count - Self.maximumEntries)
        for entry in earliest { blockedUntil[entry.key] = nil }
    }
}

public enum CommunityMapRejection: Error, Equatable, Sendable {
    case wrongSchema
    case keyMismatch
    case unknownItemDuration
    /// The map was made from a different edition (an ad inserted, an intro cut).
    case durationMismatch(serverMs: Int, itemMs: Int)
    case noScenes
    case tooManyScenes
    case sceneOutOfOrder(Int)
    case sceneOutOfRange(Int)
    case sceneText(Int)
    case contract(String)

    /// One line for Diagnostics. Never holds the episode key or any summary text.
    public var diagnostic: String {
        switch self {
        case .wrongSchema: "wrong_schema"
        case .keyMismatch: "key_mismatch"
        case .unknownItemDuration: "unknown_item_duration"
        case .durationMismatch: "duration_mismatch"
        case .noScenes: "no_scenes"
        case .tooManyScenes: "too_many_scenes"
        case .sceneOutOfOrder(let index): "scene_out_of_order:\(index)"
        case .sceneOutOfRange(let index): "scene_out_of_range:\(index)"
        case .sceneText(let index): "scene_text:\(index)"
        case .contract(let reason): "contract:\(reason)"
        }
    }
}

public struct CommunityMap: Equatable, Sendable {
    public let proposal: PortableListeningMapProposalArtifact
    public let projection: ResolvedListeningMapProjection
}

/// Turns a server map into a proposal in the existing `listening-map-proposal.v2` schema and the
/// projection that places it. Nothing is stored unless every check passes.
public enum CommunityMapConverter {
    /// The server's length for the episode must be within this of the phone's: a 30 s longer
    /// edition has an ad the map's times don't allow for, so its scenes would land in the wrong place.
    public static let durationToleranceMs = 2_000
    public static let generatorPrefix = "community:"
    public static let proposalIdPrefix = "community-map-"
    public static let sceneIdPrefix = "community-scene-"
    public static let projectionIdPrefix = "community-projection-"
    public static let maximumScenes = 60
    /// The server's own limits (research/B4/server/internal/maps/service.go).
    public static let maximumTitleCharacters = 80
    public static let maximumSummaryCharacters = 300

    public static func isCommunityProposal(id: String) -> Bool { id.hasPrefix(proposalIdPrefix) }
    public static func isCommunityProjection(_ projection: ResolvedListeningMapProjection) -> Bool {
        projection.id.hasPrefix(projectionIdPrefix) || projection.proposalId.map(isCommunityProposal(id:)) == true
    }
    /// The item page holds scenes, not the proposal, so a scene id says where the map came from.
    public static func isCommunitySceneId(_ id: String) -> Bool { id.hasPrefix(sceneIdPrefix) }

    public static func make(
        response: CommunityMapResponse,
        episodeKey: String,
        itemId: String,
        itemDurationMs: Int?,
        createdAt: Date = Date()
    ) -> Result<CommunityMap, CommunityMapRejection> {
        guard response.schema == CommunityMapResponse.schema else { return .failure(.wrongSchema) }
        guard response.episodeKey == episodeKey else { return .failure(.keyMismatch) }
        guard let itemDurationMs, itemDurationMs > 0 else { return .failure(.unknownItemDuration) }
        guard abs(response.durationMs - itemDurationMs) <= durationToleranceMs else {
            return .failure(.durationMismatch(serverMs: response.durationMs, itemMs: itemDurationMs))
        }
        guard !response.scenes.isEmpty else { return .failure(.noScenes) }
        guard response.scenes.count <= maximumScenes else { return .failure(.tooManyScenes) }

        var previousStart = -1
        for (index, scene) in response.scenes.enumerated() {
            guard scene.startMs >= 0, scene.startMs < itemDurationMs, scene.endMs >= scene.startMs,
                  scene.endMs <= itemDurationMs + durationToleranceMs else {
                return .failure(.sceneOutOfRange(index))
            }
            // A server that sends scenes out of order is not trusted to have placed them: Skim
            // walks them in order, so they are refused, not sorted.
            guard scene.startMs > previousStart else { return .failure(.sceneOutOfOrder(index)) }
            guard validText(title: scene.title, summary: scene.summary) else { return .failure(.sceneText(index)) }
            previousStart = scene.startMs
        }

        // The schema caps ids at 200 characters; an item id is a UUID, so this never cuts one.
        let idSuffix = String(episodeKey.prefix(16)) + "-" + String(itemId.prefix(120))
        let proposalId = proposalIdPrefix + idSuffix
        let scenes = response.scenes.enumerated().map { index, scene -> PortableListeningMapScene in
            let title = scene.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // A scene ends where the next starts, so nothing overlaps whatever the server sent.
            let end = index + 1 < response.scenes.count
                ? min(scene.endMs, response.scenes[index + 1].startMs)
                : min(scene.endMs, itemDurationMs)
            return PortableListeningMapScene(
                id: sceneIdPrefix + "\(index + 1)", order: index, title: title,
                summaryText: scene.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                summaryProvenance: .modelGenerated, eligibility: .eligible,
                eligibilityReason: "Community map; the summary was made from another listener's transcript.",
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: scene.startMs, chapterTitle: title),
                endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: end, chapterTitle: title)
            )
        }
        let generator = String((generatorPrefix + response.generator.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(200))
        let proposal = PortableListeningMapProposalArtifact(
            id: proposalId, createdAt: createdAt, generator: generator, scenes: scenes
        )
        // The same checks a map passes before it travels in a packet: only an eligible scene has a
        // summary, scenes run forward, and none quotes its source (no transcript is held here).
        if let violation = PortableListeningMapContract.violations(in: proposal).first {
            return .failure(.contract(violation.description))
        }
        // The map's times are the phone's own: the lengths agree, so no matching is needed.
        let starts = response.scenes.map(\.startMs) + [itemDurationMs]
        let projection = ResolvedListeningMapProjection(
            id: projectionIdPrefix + idSuffix,
            itemId: itemId, proposalId: proposalId, createdAt: createdAt,
            algorithmVersion: "episode-projection.exact-edition.v1",
            points: starts.enumerated().map { index, time in
                ResolvedListeningMapPoint(
                    id: "boundary-\(index)", sourceMediaTimeMs: time, recipientMediaTimeMs: time,
                    confidence: .exactEdition, evidenceIds: []
                )
            },
            intervals: []
        )
        return .success(CommunityMap(proposal: proposal, projection: projection))
    }

    /// A scene's title and summary are spoken and shown, so they must be plain, short and not
    /// instruction-like text (the same phrases the on-device label check refuses).
    static func validText(title rawTitle: String, summary rawSummary: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !summary.isEmpty,
              title.count <= maximumTitleCharacters, summary.count <= maximumSummaryCharacters else { return false }
        let spoken = " \(ListeningMapSummaryValidator.words("\(title) \(summary)").joined(separator: " ")) "
        return !ListeningMapSummaryValidator.instructionPhrases.contains { spoken.contains(" \($0) ") }
    }
}

public enum CommunityMapFetchOutcome: Equatable, Sendable {
    case skipped(CommunityMapFetchSkipReason)
    /// The server's `maps` service isn't usable now.
    case mapsOff(ServerFeatureOffReason)
    case stored(sceneCount: Int)
    /// The server has no map for this episode (404 or 410).
    case notFound
    /// The map was refused, and nothing was stored.
    case unusable(String)
    case failed(String)

    /// How long the app leaves the episode alone, or nil when asking again at once costs nothing
    /// (the phone's own reasons for a skip, or no config yet). The server being reachable but
    /// switching the service off waits as long as a missing map does.
    public var retryAfter: TimeInterval? {
        switch self {
        case .skipped: nil
        case .mapsOff(let reason):
            switch reason {
            case .switchedOff, .buildTooOld: CommunityMapFetchPolicy.recheckInterval
            default: nil
            }
        case .stored, .notFound, .unusable: CommunityMapFetchPolicy.recheckInterval
        case .failed: CommunityMapFetchPolicy.failureRetryInterval
        }
    }

    /// One line for Diagnostics. Never holds the episode key, a URL or any summary text.
    public var diagnostic: String {
        switch self {
        case .skipped(let reason): "skipped:\(reason.rawValue)"
        case .mapsOff: "skipped:maps_off"
        case .stored(let count): "stored:\(count)"
        case .notFound: "not_found"
        case .unusable(let reason): "unusable:\(reason)"
        case .failed(let reason): "failed:\(reason)"
        }
    }
}

public struct CommunityMapFetcher: Sendable {
    public static let mapsURL = ProductServer.url(path: "/api/v1/maps/")
    /// A map is a few dozen short scenes; this is far above the biggest the server can make.
    public static let maximumBytes = 64 * 1_024
    /// An unanswered request is dropped with no message to the listener.
    public static let timeoutSeconds: TimeInterval = 5

    private let baseURL: URL
    private let get: SourceHTTPFetch
    private let timeoutSeconds: TimeInterval

    public init(baseURL: URL = Self.mapsURL, timeoutSeconds: TimeInterval = Self.timeoutSeconds, get: @escaping SourceHTTPFetch) {
        self.baseURL = baseURL
        self.timeoutSeconds = timeoutSeconds
        self.get = get
    }

    /// Asks the server for the episode's map once, if every rule allows it, and hands a valid map
    /// to `store`. Never throws: a switched-off server, a 404, a timeout or a bad answer leave the
    /// episode as it was, and the outcome only goes to Diagnostics.
    ///
    /// - `optedIn` is read first, before anything else is read or sent, and again just before the
    ///   server is asked (even for its config), so turning the setting off while the phone reads
    ///   the audio file or the store still stops the request.
    /// - The phone's cheap rules run first and `localState` (which reads the transcript and may
    ///   read the audio file) only for an episode that passes them, so articles, private feeds and
    ///   episodes asked about a moment ago cost nothing. `localState` is read again just before
    ///   storing, and `store` does its own check inside its transaction.
    /// - `mapsState` is read only for an episode that can take a community map, so an episode
    ///   with chapters or a map of its own makes no request at all.
    /// - `audioDurationMs` is asked only when the feed gave no length.
    /// - `store` returns false when the episode got a map of its own meanwhile; nothing is replaced.
    public func fetchIfEligible(
        item: Item,
        blockedUntil: Date?,
        now: Date = Date(),
        optedIn: @Sendable () async -> Bool,
        localState: @Sendable () async -> CommunityMapLocalState,
        mapsState: @Sendable () async -> ServerFeatureState,
        audioDurationMs: @Sendable () async -> Int? = { nil },
        store: @Sendable (CommunityMap) throws -> Bool
    ) async -> CommunityMapFetchOutcome {
        guard await optedIn() else { return .skipped(.optedOut) }
        let nothingHeld = CommunityMapLocalState(hasPublisherChapters: false, hasMap: false)
        var measured: Int?
        var screen = CommunityMapFetchPolicy.decide(optedIn: true, item: item, local: nothingHeld, blockedUntil: blockedUntil, now: now)
        if case .skip(.unknownDuration) = screen {
            measured = await audioDurationMs()
            screen = CommunityMapFetchPolicy.decide(
                optedIn: true, item: item, local: nothingHeld, blockedUntil: blockedUntil, audioDurationMs: measured, now: now
            )
        }
        guard case .fetch = screen else {
            if case .skip(let reason) = screen { return .skipped(reason) }
            return .skipped(.noEpisodeKey)
        }
        let decision = CommunityMapFetchPolicy.decide(
            optedIn: true, item: item, local: await localState(), blockedUntil: blockedUntil, audioDurationMs: measured, now: now
        )
        guard case .fetch(let episodeKey) = decision else {
            if case .skip(let reason) = decision { return .skipped(reason) }
            return .skipped(.noEpisodeKey)
        }
        // Reading the audio file and the store can take a while; the setting may be off by now.
        guard await optedIn() else { return .skipped(.optedOut) }
        if case .off(let reason) = await mapsState() { return .mapsOff(reason) }
        // The config read is a network round trip; the setting may have been turned off during it.
        guard await optedIn() else { return .skipped(.optedOut) }

        let body: Data
        do {
            let url = baseURL.appending(path: episodeKey)
            let get = self.get
            let (status, data) = try await Self.withTimeout(seconds: timeoutSeconds) {
                try await get(url, Self.maximumBytes)
            }
            switch status {
            case 200: body = data
            case 404, 410: return .notFound
            default: return .failed(String(status))
            }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as URLError where error.code == .timedOut {
            return .failed("timeout")
        } catch {
            return .failed("network")
        }

        guard let response = try? JSONDecoder().decode(CommunityMapResponse.self, from: body) else {
            return .unusable("malformed")
        }
        let map: CommunityMap
        switch CommunityMapConverter.make(
            response: response, episodeKey: episodeKey, itemId: item.id,
            itemDurationMs: CommunityMapUploadPolicy.durationMs(item: item, audioDurationMs: measured), createdAt: now
        ) {
        case .success(let converted): map = converted
        case .failure(let rejection): return .unusable(rejection.diagnostic)
        }
        // Nothing the listener got while the request was out is replaced.
        let latest = await localState()
        if latest.hasPublisherChapters { return .skipped(.publisherChapters) }
        if latest.hasMap { return .skipped(.hasMap) }
        do {
            guard try store(map) else { return .skipped(.hasMap) }
        } catch {
            return .failed("storage")
        }
        return .stored(sceneCount: map.proposal.scenes.count)
    }

    /// Runs `operation`, giving up after `seconds` with `URLError(.timedOut)`.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }
}
