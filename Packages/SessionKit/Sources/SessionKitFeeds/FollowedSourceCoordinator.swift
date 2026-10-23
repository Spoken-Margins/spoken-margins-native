#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit

public enum FollowedSourceError: Error, LocalizedError {
    case invalidURL
    case insecureURL
    case responseTooLarge
    case htmlResponseTooLarge
    case invalidResponse
    case noFeedCandidates

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid feed URL."
        case .insecureURL: "Followed sources must use HTTPS."
        case .responseTooLarge: "The feed exceeds the 16 MB safety limit."
        case .htmlResponseTooLarge: "The source website exceeds the 1 MB discovery limit. Try its RSS feed URL directly."
        case .invalidResponse: "The source did not return a supported feed."
        case .noFeedCandidates: "This website doesn't offer a feed Spoken Margins can follow."
        }
    }

    /// For diagnostics (#244): the case, not just the type name.
    public var diagnosticCode: String {
        switch self {
        case .invalidURL: "invalid_url"
        case .insecureURL: "insecure_url"
        case .responseTooLarge: "response_too_large"
        case .htmlResponseTooLarge: "html_response_too_large"
        case .invalidResponse: "invalid_response"
        case .noFeedCandidates: "no_feed_candidates"
        }
    }
}

/// What `FollowedSourceCoordinator.publisherAudioLookup` found for a followed entry (#2024): the entry, confirmed when
/// the post page names its publisher's voice, and a short diagnostic token saying what happened.
public struct PublisherAudioLookup: Equatable, Sendable {
    public let entry: FeedEntry
    public let outcome: String
}

/// Why a publisher's post page is being read (#2368). Only a listener's own action, or the format check that runs
/// without any listener, may fetch one; an import that nobody asked for (Following's "Add every new item") reads the
/// feed and nothing else, and the page is looked up the first time the listener opens or plays the item.
public enum PublisherPageFetchTrigger: Sendable {
    /// The listener tapped Add, Add and open, or Play on this post.
    case listenerAction
    /// The scheduled Substack format check reads a handful of public pages.
    case formatCheck
    /// A refresh imported the entry by itself.
    case background
}

public actor FollowedSourceCoordinator {
    private static let maximumFeedBytes = FeedParserLimits.defaultMaximumBytes
    public static let maximumRetainedSuggestionsPerFeed = 25
    private let repository: any SessionRepository
    private let session: URLSession
    private let parser = FeedParser()
    public private(set) var contactedHosts: Set<String> = []
    /// What each discovery step saw on the last `discover`, for diagnostics (#244). Hosts and
    /// error codes only, never a full link.
    private(set) var lastDiscoveryTrace: [String] = []
    private var lastDiscoveryHost = "unknown"
    /// Where newly seen entries are logged as I4 `item_published` rows (#483).
    private let signals: ListeningSignalRecorder?
    /// Each followed show's artwork, in a side file beside the database (#773).
    private var artwork: FollowingArtworkStore

    public init(repository: any SessionRepository, session: URLSession? = nil, artworkFile: URL? = nil,
                signals: ListeningSignalRecorder?) {
        self.repository = repository
        self.artwork = FollowingArtworkStore(file: artworkFile)
        self.signals = signals
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: BoundedRedirectDelegate(maximumRedirects: 5), delegateQueue: nil)
        }
    }

    public func follow(urlString: String) async throws -> FeedSubscription {
        let candidates = try await discover(urlString: urlString)
        guard let candidate = candidates.first else { throw FollowedSourceError.noFeedCandidates }
        return try await follow(candidate: candidate)
    }

    /// Follows a feed link once. A feed that is already followed keeps its subscription exactly
    /// as it is (mute state and inbox entries), so the drawer and OPML import can't duplicate it.
    public func followFeed(urlString: String) async throws -> FeedSubscription {
        guard let candidate = try await discover(urlString: urlString).first else { throw FollowedSourceError.noFeedCandidates }
        if let existing = try repository.loadFeedSubscriptions().first(where: { $0.source.id == candidate.source.id }) {
            return existing
        }
        return try await follow(candidate: candidate)
    }

    public func discover(urlString: String, requiringItemMembership: Bool = false) async throws -> [SourceCandidateEvidence] {
        let link = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDiscoveryTrace = []
        guard let url = URL(string: link) else { throw FollowedSourceError.invalidURL }
        lastDiscoveryHost = url.host?.lowercased() ?? "unknown"
        contactedHosts = []
        if url.scheme?.lowercased() == "https" {
            do {
                let parsed = try await fetch(url: url, subscription: nil)
                return [candidate(url: url, parsed: parsed, relation: "direct", confidence: 1)]
            } catch {
                lastDiscoveryTrace.append("direct: not a feed (\(Self.diagnosticCode(for: error)))")
            }
        }
        // B2: a Substack post, home page, share link or profile names its publication by origin,
        // so old and tracked links need no feed membership. Other sites return nil here.
        if let substack = await substackCandidate(for: link) {
            return [substack]
        }
        do {
            return try await genericDiscover(url: url, requiringItemMembership: requiringItemMembership)
        } catch {
            lastDiscoveryTrace.append("generic: \(Self.diagnosticCode(for: error))")
            throw error
        }
    }

    /// One line for diagnostics after a failed Follow (#244): the error case, the host, and what
    /// each discovery step saw.
    public func failureDiagnostic(for error: Error) -> String {
        let steps = lastDiscoveryTrace.isEmpty ? "none" : lastDiscoveryTrace.joined(separator: " | ")
        return "\(Self.diagnosticCode(for: error)) host=\(lastDiscoveryHost) steps=\(steps)"
    }

    public static func diagnosticCode(for error: Error) -> String {
        if let followError = error as? FollowedSourceError { return followError.diagnosticCode }
        if let parserError = error as? FeedParserError { return "feed_\(parserError)" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    private func genericDiscover(url: URL, requiringItemMembership: Bool) async throws -> [SourceCandidateEvidence] {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { throw FollowedSourceError.insecureURL }
        contactedHosts.insert(host)
        let html = try await fetchHTML(url: url)
        var evidence: [(URL, String, Double)] = Self.alternateFeedURLs(in: html, baseURL: url)
            .map { ($0, "html_alternate", 0.95) }
        for path in ["/feed", "/feed.xml", "/rss", "/atom.xml"] {
            if let candidate = URL(string: path, relativeTo: url)?.absoluteURL,
               candidate.host?.caseInsensitiveCompare(host) == .orderedSame,
               !evidence.contains(where: { $0.0 == candidate }) {
                evidence.append((candidate, "same_origin_heuristic", 0.55))
            }
        }
        var candidates: [SourceCandidateEvidence] = []
        var seenFeedContents = Set<String>()
        for (candidateURL, relation, confidence) in evidence.prefix(8) {
            guard let parsed = try? await fetch(url: candidateURL, subscription: nil) else { continue }
            // Discovery is evidence of membership, not merely a feed on the
            // same host. Unmatched heuristics must never become follow consent.
            guard !requiringItemMembership || parsed.items.contains(where: {
                Self.itemURLKey($0.url) == Self.itemURLKey(url.absoluteString)
                    || Self.itemURLKey($0.audioURL) == Self.itemURLKey(url.absoluteString)
            }) else { continue }
            // Alternate feed formats can have different URLs but the same entries.
            // Compare actual membership, never publication title alone.
            let entryURLs = Set(parsed.items.compactMap { Self.itemURLKey($0.url) }).sorted()
            if !entryURLs.isEmpty {
                let contentKey = entryURLs.joined(separator: "\n")
                guard seenFeedContents.insert(contentKey).inserted else { continue }
            }
            let found = candidate(url: candidateURL, parsed: parsed, relation: relation, confidence: confidence)
            if !candidates.contains(where: { $0.source.id == found.source.id }) {
                candidates.append(found)
            }
        }
        guard !candidates.isEmpty else { throw FollowedSourceError.noFeedCandidates }
        return candidates
    }

    private static func itemURLKey(_ raw: String?) -> String? {
        guard let raw, var url = URLComponents(string: raw) else { return nil }
        url.fragment = nil
        url.host = url.host?.lowercased()
        url.scheme = url.scheme?.lowercased()
        return url.string
    }

    public func follow(candidate: SourceCandidateEvidence) async throws -> FeedSubscription {
        guard let url = URL(string: candidate.source.canonicalURL) else { throw FollowedSourceError.invalidURL }
        let parsed = try await fetch(url: url, subscription: nil)
        let host = url.host?.lowercased() ?? candidate.source.host
        let canonical = URL(string: parsed.feedURL ?? url.absoluteString) ?? url
        let sourceId = "source-\(Self.digest(canonical.absoluteString.lowercased()))"
        // Following a feed again keeps its new-item choice (#466) and its follow moment (#1589):
        // a feed already followed has no new back catalogue, and its waiting entries stay New.
        let previous = try repository.loadFeedSubscriptions().first { $0.id == "subscription-\(sourceId)" }
        let previousPolicy = previous?.newItemPolicy
        let subscription = FeedSubscription(
            id: "subscription-\(sourceId)",
            source: SourceIdentity(
                id: sourceId,
                kind: parsed.items.contains(where: { $0.audioURL != nil }) ? .podcastFeed : .articleFeed,
                canonicalURL: canonical.absoluteString,
                host: canonical.host?.lowercased() ?? host,
                title: parsed.title
            ),
            createdAt: previous?.createdAt ?? Date(),
            newItemPolicy: previousPolicy
        )
        try repository.saveFeedSubscription(subscription)
        // What a feed has the first time it is followed is its back catalogue: only entries it
        // publishes after this moment are New (#1589). The entries are kept, stamped with it.
        try save(entries: parsed.items, subscription: subscription, followMoment: previous == nil ? subscription.createdAt : nil)
        artwork.recordFeedArtwork(parsed.imageURL, for: subscription.id)
        return subscription
    }

    private func candidate(url: URL, parsed: ParsedFeed, relation: String, confidence: Double) -> SourceCandidateEvidence {
        let canonical = URL(string: parsed.feedURL ?? url.absoluteString) ?? url
        let sourceId = "source-\(Self.digest(canonical.absoluteString.lowercased()))"
        return SourceCandidateEvidence(
            id: "candidate-\(sourceId)",
            source: SourceIdentity(
                id: sourceId,
                kind: parsed.items.contains(where: { $0.audioURL != nil }) ? .podcastFeed : .articleFeed,
                canonicalURL: canonical.absoluteString,
                host: canonical.host?.lowercased() ?? url.host?.lowercased() ?? "unknown",
                title: parsed.title
            ),
            evidenceURL: url.absoluteString,
            relation: relation,
            confidence: confidence
        )
    }

    /// Returns the entries that feeds set to "Add every new item" want added to the Library (#466).
    /// They stay unseen here; the caller imports them, which marks them imported.
    @discardableResult
    public func refreshStale(now: Date = Date(), minimumAge: TimeInterval = 6 * 60 * 60, force: Bool = false) async -> [FeedEntry] {
        var toAdd: [FeedEntry] = []
        for subscription in (try? repository.loadFeedSubscriptions()) ?? [] {
            // A background refresh that iOS cuts short stops here, not by failing every feed left (#170).
            if Task.isCancelled { break }
            guard force || subscription.lastRefreshAt.map({ now.timeIntervalSince($0) >= minimumAge }) ?? true else { continue }
            toAdd += await refresh(subscription, now: now)
        }
        return toAdd
    }

    public func entries() throws -> [FeedEntry] {
        let muted = Set(try repository.loadFeedSubscriptions().filter { $0.state == .muted }.map(\.id))
        return try repository.loadFeedEntries(subscriptionId: nil)
            .filter { !muted.contains($0.subscriptionId) && $0.state != .dismissed && $0.state != .imported }
            .sorted {
                if $0.publishedAt != $1.publishedAt { return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                return $0.id < $1.id
            }
    }

    public func setEntryState(id: String, state: FeedEntryState) throws {
        guard var entry = try repository.loadFeedEntries(subscriptionId: nil).first(where: { $0.id == id }) else { return }
        entry.state = state
        try repository.saveFeedEntry(entry)
    }

    /// Dismisses `id` and returns the state it had, for Undo (#477). Nil when there is no such entry
    /// or it was already dismissed, so there is nothing to undo.
    public func dismissEntry(id: String) throws -> FeedEntryState? {
        guard let entry = try repository.loadFeedEntries(subscriptionId: nil).first(where: { $0.id == id }),
              entry.state != .dismissed else { return nil }
        try setEntryState(id: id, state: .dismissed)
        return entry.state
    }

    /// Puts an entry dismissed by `dismissEntry` back in the state it had (#477). It does nothing if
    /// the entry has moved on since, for instance imported from another screen.
    public func undoDismissEntry(id: String, restoring previous: FeedEntryState) throws {
        guard let entry = try repository.loadFeedEntries(subscriptionId: nil).first(where: { $0.id == id }),
              entry.state == .dismissed else { return }
        try setEntryState(id: id, state: previous)
    }

    /// Dismisses every entry in `ids` that is not dismissed already, for "Clear" on the New list
    /// (#1589). Returns the state each had, for one Undo. Imported entries stay imported.
    public func dismissEntries(ids: [String]) throws -> [String: FeedEntryState] {
        let wanted = Set(ids)
        var previous: [String: FeedEntryState] = [:]
        for var entry in try repository.loadFeedEntries(subscriptionId: nil)
        where wanted.contains(entry.id) && entry.state != .dismissed && entry.state != .imported {
            previous[entry.id] = entry.state
            entry.state = .dismissed
            try repository.saveFeedEntry(entry)
        }
        return previous
    }

    /// Puts entries cleared by `dismissEntries` back in the state each had. One that has moved on
    /// since, for instance imported from another screen, is left alone.
    public func undoDismissEntries(restoring previous: [String: FeedEntryState]) throws {
        for var entry in try repository.loadFeedEntries(subscriptionId: nil)
        where entry.state == .dismissed {
            guard let state = previous[entry.id] else { continue }
            entry.state = state
            try repository.saveFeedEntry(entry)
        }
    }

    /// An ambiguous enclosure remains a podcast if corroboration fails. Public page metadata
    /// identifies narration without extracting or replacing subscriber feed text.
    public func publisherAudioEntry(for entry: FeedEntry, trigger: PublisherPageFetchTrigger) async -> FeedEntry {
        await publisherAudioLookup(for: entry, trigger: trigger).entry
    }

    /// `publisherAudioEntry`, with a short token saying what the lookup found or why it kept no publisher voice,
    /// for the `followedPublisherAudio` diagnostic (#2024). Tokens carry no address or page text.
    public func publisherAudioLookup(for entry: FeedEntry, trigger: PublisherPageFetchTrigger) async -> PublisherAudioLookup {
        if entry.publisherNarrationConfirmed == true {
            return PublisherAudioLookup(entry: entry, outcome: "already_confirmed")
        }
        // No page is read for an import the listener didn't start (#2368); opening the item looks it up then.
        if trigger == .background, entry.publisherPlatform == "substack" {
            return PublisherAudioLookup(entry: entry, outcome: "deferred_until_opened")
        }
        guard entry.publisherPlatform == "substack" else {
            return PublisherAudioLookup(entry: entry, outcome: "not_substack:\(entry.publisherPlatform == nil ? "none" : "other")")
        }
        let words = entry.bodyWordCount ?? 0
        guard words >= PublisherAudioDetector.minimumBodyWords else {
            return PublisherAudioLookup(entry: entry, outcome: "short_body:\(entry.bodyWordCount.map(String.init) ?? "unknown")")
        }
        guard let url = Self.validHTTPSURL(entry.canonicalURL) else {
            return PublisherAudioLookup(entry: entry, outcome: "invalid_url")
        }
        let html: String
        do {
            let page = try await loadHTML(url: url)
            guard (200..<300).contains(page.status) else {
                return PublisherAudioLookup(entry: entry, outcome: "fetch_failed:http_\(page.status)")
            }
            guard let text = page.html else { return PublisherAudioLookup(entry: entry, outcome: "fetch_failed:too_large") }
            html = text
        } catch {
            let token = (error as? URLError).map { "url_error_\($0.code.rawValue)" } ?? String(describing: type(of: error))
            return PublisherAudioLookup(entry: entry, outcome: "fetch_failed:\(token)")
        }
        guard let confirmed = PublisherNarrationEvidence.confirmedEntry(entry, html: html) else {
            let found = PublisherNarrationEvidence.voiceover(inPostPage: html) ?? PublisherNarrationEvidence.generatedVoice(inPostPage: html)
            let reason = found == nil ? PublisherNarrationEvidence.absence(inPostPage: html) : "url_mismatch"
            return PublisherAudioLookup(entry: entry, outcome: "none:\(reason)")
        }
        // A refresh, dismissal or unfollow may finish while the page request awaits. Cache only
        // against the unchanged entry, so corroboration cannot restore a removed/stale row.
        try? PublisherNarrationEvidence.cache(confirmed, replacing: entry, in: repository)
        return PublisherAudioLookup(entry: confirmed, outcome: confirmed.publisherNarrationGenerated == true ? "found:generated_voice" : "found:voiceover")
    }

    /// How Following adds `entry` (#641). For an entry that could be an episode, this looks up its
    /// audio, refetching the feed for an older entry saved without its enclosure.
    public func importRoute(for entry: FeedEntry, subscriptionKind: SourceIdentityKind) async throws -> FollowedEntryImportRoute {
        guard FollowedEntryImportRoute.needsAudioLookup(for: entry, subscriptionKind: subscriptionKind) else { return .article }
        let known = try await audio(for: entry)
        return FollowedEntryImportRoute.route(for: entry, subscriptionKind: subscriptionKind, audio: known)
    }

    public func playableAudioURL(for entry: FeedEntry) async throws -> String? {
        guard case .found(let audioURL) = try await audio(for: entry) else { return nil }
        return Self.validHTTPSURL(audioURL)?.absoluteString
    }

    /// The entry's audio: its stored https enclosure, or the one the feed lists for it now (saved
    /// on the entry). The feed listing the entry with no audio at all marks a text-only post.
    public func audio(for entry: FeedEntry) async throws -> FollowedEntryAudio {
        if let audioURL = Self.validHTTPSURL(entry.audioURL) {
            return .found(audioURL.absoluteString)
        }
        let stored = FollowedEntryAudio.stored(in: entry)
        guard let subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == entry.subscriptionId }),
              subscription.source.kind == .podcastFeed,
              let feedURL = URL(string: subscription.source.canonicalURL) else {
            return stored
        }
        let parsed = try await fetch(url: feedURL, subscription: nil)
        guard let match = parsed.items.first(where: { item in
            item.url == entry.canonicalURL
                || (item.title == entry.title && item.publishedAt == entry.publishedAt)
        }) else {
            return stored
        }
        guard let audioURL = Self.validHTTPSURL(match.audioURL) else {
            return entry.audioURL == nil && match.audioURL == nil ? .noneInFeed : stored
        }
        var updated = entry
        updated.audioURL = audioURL.absoluteString
        try repository.saveFeedEntry(updated)
        return .found(audioURL.absoluteString)
    }

    public func setNewItemPolicy(subscriptionId: String, policy: FeedNewItemPolicy) throws {
        guard var subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == subscriptionId }) else { return }
        subscription.newItemPolicy = policy
        try repository.saveFeedSubscription(subscription)
    }

    public func setMuted(subscriptionId: String, muted: Bool) throws {
        guard var subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == subscriptionId }) else { return }
        subscription.state = muted ? .muted : .active
        try repository.saveFeedSubscription(subscription)
    }

    public func unfollow(subscriptionId: String) throws {
        for entry in try repository.loadFeedEntries(subscriptionId: subscriptionId) where entry.state != .imported {
            try repository.deleteFeedEntry(id: entry.id)
        }
        try repository.deleteFeedSubscription(id: subscriptionId)
        artwork.remove(subscriptionID: subscriptionId)
    }

    /// Following rows' artwork (#773): drops shows no longer followed and records the catalog's
    /// artwork for followed shows it lists.
    public func followingArtwork(catalog: SourceCatalog? = nil) -> FollowingArtworkCache {
        if let subscriptions = try? repository.loadFeedSubscriptions() {
            artwork.reconcile(with: subscriptions, catalog: catalog)
        }
        return artwork.cache
    }

    private func refresh(_ original: FeedSubscription, now: Date) async -> [FeedEntry] {
        var subscription = original
        var toAdd: [FeedEntry] = []
        do {
            let parsed = try await fetch(url: URL(string: subscription.source.canonicalURL)!, subscription: subscription)
            // Mute and the new-item choice may have changed during the fetch; the latest ones win.
            // An unfollow during the fetch wins too: nothing is saved or added.
            guard let current = try repository.loadFeedSubscriptions().first(where: { $0.id == subscription.id }) else { return [] }
            subscription.state = current.state
            subscription.newItemPolicy = current.newItemPolicy
            let saved = try save(entries: parsed.items, subscription: subscription)
            artwork.recordFeedArtwork(parsed.imageURL, for: subscription.id)
            // A muted feed adds nothing on its own.
            toAdd = FeedNewItemPolicy.entriesToAdd(
                new: saved.entries, existing: saved.previous,
                policy: subscription.state == .muted ? nil : subscription.newItemPolicy
            )
            subscription.lastRefreshAt = now
            try repository.saveFeedSubscription(subscription)
            try repository.saveFeedRefreshState(FeedRefreshState(
                id: "refresh-\(subscription.id)",
                subscriptionId: subscription.id,
                status: .succeeded,
                checkedAt: now,
                redactedHost: subscription.source.host
            ))
        } catch let error as HTTPNotModified {
            subscription.lastRefreshAt = now
            try? repository.saveFeedSubscription(subscription)
            try? repository.saveFeedRefreshState(FeedRefreshState(
                id: "refresh-\(subscription.id)", subscriptionId: subscription.id,
                status: .notModified, checkedAt: now, redactedHost: subscription.source.host,
                errorCode: error.localizedDescription
            ))
        } catch {
            // A refresh iOS cut short is not a failed feed; it stays stale and is tried again (#170).
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return toAdd }
            try? repository.saveFeedRefreshState(FeedRefreshState(
                id: "refresh-\(subscription.id)", subscriptionId: subscription.id,
                status: .failed, checkedAt: now, redactedHost: subscription.source.host,
                errorCode: String(describing: type(of: error))
            ))
        }
        return toAdd
    }

    private func fetch(url: URL, subscription: FeedSubscription?) async throws -> ParsedFeed {
        if let host = url.host?.lowercased() { contactedHosts.insert(host) }
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml", forHTTPHeaderField: "Accept")
        if let etag = subscription?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = subscription?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FollowedSourceError.invalidResponse }
        if http.statusCode == 304 { throw HTTPNotModified() }
        guard (200..<300).contains(http.statusCode) else { throw FollowedSourceError.invalidResponse }
        guard data.count <= Self.maximumFeedBytes else { throw FollowedSourceError.responseTooLarge }
        var parsed = try parser.parse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        // RSS often omits a self link. Redirect aliases must use the final
        // response URL, otherwise /feed and /rss become separate sources.
        let responseURL = http.url ?? url
        parsed.feedURL = parsed.feedURL.flatMap {
            URL(string: $0, relativeTo: responseURL)?.absoluteURL.absoluteString
        } ?? responseURL.absoluteString
        return parsed
    }

    private func substackCandidate(for link: String) async -> SourceCandidateEvidence? {
        let resolver = SubstackPublicationResolver { url, kind in
            try await self.substackFetch(url: url, kind: kind)
        }
        let resolution = await resolver.resolveExplained(link)
        lastDiscoveryTrace.append(contentsOf: resolution.trace.map { "substack: \($0)" })
        guard let publication = resolution.publication,
              let feedURL = URL(string: publication.feedURL) else { return nil }
        return candidate(
            url: feedURL,
            parsed: publication.feed,
            relation: publication.isCertain ? publication.kind.rawValue : SourceCandidateEvidence.substackProfileRelation,
            confidence: publication.confidence
        )
    }

    /// Substack probes read /feed and substack.com pages only. Pages are capped higher than the
    /// generic 1 MB discovery limit because only their final URL and headers matter.
    private func substackFetch(url: URL, kind: SubstackFetchKind) async throws -> SubstackFetchResponse {
        if let host = url.host?.lowercased() { contactedHosts.insert(host) }
        var request = URLRequest(url: url)
        request.setValue(
            kind == .feed
                ? "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml"
                : "text/html, application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FollowedSourceError.invalidResponse }
        guard data.count <= (kind == .feed ? Self.maximumFeedBytes : 4 * 1_024 * 1_024) else {
            throw FollowedSourceError.responseTooLarge
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return SubstackFetchResponse(url: http.url ?? url, status: http.statusCode, headers: headers, body: data)
    }

    private func fetchHTML(url: URL) async throws -> String {
        let page = try await loadHTML(url: url)
        guard (200..<300).contains(page.status) else { throw FollowedSourceError.invalidResponse }
        guard let html = page.html else { throw FollowedSourceError.htmlResponseTooLarge }
        return html
    }

    /// The page's HTTP status and its text, or nil text past the 1 MB limit.
    private func loadHTML(url: URL) async throws -> (status: Int, html: String?) {
        var request = URLRequest(url: url)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FollowedSourceError.invalidResponse }
        return (http.statusCode, data.count <= 1 * 1_024 * 1_024 ? String(decoding: data, as: UTF8.self) : nil)
    }

    private static func alternateFeedURLs(in html: String, baseURL: URL) -> [URL] {
        let pattern = #"<link\b[^>]*\brel\s*=\s*['\"][^'\"]*alternate[^'\"]*['\"][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [URL] = []
        for match in regex.matches(in: html, range: range).prefix(8) {
            guard let swiftRange = Range(match.range, in: html) else { continue }
            let tag = String(html[swiftRange])
            guard tag.range(of: #"type\s*=\s*['\"](?:application/(?:rss\+xml|atom\+xml|feed\+json|json)|text/xml)['\"]"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let hrefRange = tag.range(of: #"href\s*=\s*['\"][^'\"]+['\"]"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let attribute = String(tag[hrefRange])
            guard let firstQuote = attribute.firstIndex(where: { $0 == "\"" || $0 == "'" }),
                  let lastQuote = attribute.lastIndex(where: { $0 == "\"" || $0 == "'" }),
                  firstQuote < lastQuote else { continue }
            let value = String(attribute[attribute.index(after: firstQuote)..<lastQuote])
            guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https" else { continue }
            if !results.contains(url) { results.append(url) }
        }
        return results
    }

    /// Returns the retained entries as saved, and the entries the feed had before this save.
    @discardableResult
    private func save(entries: [ParsedFeedItem], subscription: FeedSubscription, followMoment: Date? = nil) throws -> (entries: [FeedEntry], previous: [FeedEntry]) {
        let existingEntries = try repository.loadFeedEntries(subscriptionId: subscription.id)
        let existing = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
        let retainedItems = entries.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.publishedAt, rhs.element.publishedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .prefix(Self.maximumRetainedSuggestionsPerFeed)
            .map { $0.element }
        let retainedIDs = Set(retainedItems.map { Self.entryID(subscriptionID: subscription.id, itemID: $0.id) })

        let seenAt = Date()
        var saved: [FeedEntry] = []
        for item in retainedItems {
            let id = Self.entryID(subscriptionID: subscription.id, itemID: item.id)
            let entry = FeedEntry(
                id: id,
                subscriptionId: subscription.id,
                canonicalURL: item.url,
                audioURL: Self.validHTTPSURL(item.audioURL)?.absoluteString,
                title: item.title,
                author: item.author,
                summary: item.summary,
                publishedAt: item.publishedAt,
                state: existing[id]?.state ?? .unseen,
                bodyWordCount: PublisherAudioDetector.bodyWordCount(of: item),
                fullBody: item.content,
                publisherPlatform: item.publisherPlatform,
                audioDurationMs: item.durationMs,
                episodeGUID: item.guid,
                firstSeenAt: FollowBaseline.firstSeenAt(existing: existing[id], followMoment: followMoment, now: seenAt)
            )
            try repository.saveFeedEntry(entry)
            saved.append(entry)
            // Every retained entry, stored or not: the recorder publishes each one once, so entries
            // saved before this build (or before a re-follow) still get their publication row.
            signals?.record(.itemPublished, source: ListeningSignalContext.source(for: subscription), item: ListeningSignalContext.item(for: entry, seenAt: seenAt, durationMs: item.durationMs), at: seenAt)
        }

        for entry in existingEntries where !retainedIDs.contains(entry.id) {
            // Imported and dismissed entries are suppression tombstones, not Quick Add
            // suggestions. Keep them so an older episode cannot reappear later.
            guard entry.state == .unseen || entry.state == .seen else { continue }
            try repository.deleteFeedEntry(id: entry.id)
        }
        return (saved, existingEntries)
    }

    private static func entryID(subscriptionID: String, itemID: String) -> String {
        "entry-\(digest(subscriptionID + "\u{1f}" + itemID))"
    }

    private static func validHTTPSURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private struct HTTPNotModified: Error, LocalizedError {
    var errorDescription: String? { "not_modified" }
}

private final class BoundedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumRedirects: Int
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    init(maximumRedirects: Int) { self.maximumRedirects = maximumRedirects }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = lock.withLock { () -> Bool in
            let count = counts[task.taskIdentifier, default: 0] + 1
            counts[task.taskIdentifier] = count
            return count <= maximumRedirects && request.url?.scheme?.lowercased() == "https"
        }
        completionHandler(allowed ? request : nil)
    }
}
