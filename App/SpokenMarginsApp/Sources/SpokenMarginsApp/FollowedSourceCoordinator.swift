import CryptoKit
import Foundation
import SessionKit
import SessionKitFeeds

enum FollowedSourceError: Error, LocalizedError {
    case invalidURL
    case insecureURL
    case responseTooLarge
    case htmlResponseTooLarge
    case invalidResponse
    case noFeedCandidates

    var errorDescription: String? {
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
    var diagnosticCode: String {
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

actor FollowedSourceCoordinator {
    private static let maximumFeedBytes = FeedParserLimits.defaultMaximumBytes
    static let maximumRetainedSuggestionsPerFeed = 25
    private let repository: any SessionRepository
    private let session: URLSession
    private let parser = FeedParser()
    private(set) var contactedHosts: Set<String> = []
    /// What each discovery step saw on the last `discover`, for diagnostics (#244). Hosts and
    /// error codes only, never a full link.
    private(set) var lastDiscoveryTrace: [String] = []
    private var lastDiscoveryHost = "unknown"

    init(repository: any SessionRepository, session: URLSession? = nil) {
        self.repository = repository
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

    func follow(urlString: String) async throws -> FeedSubscription {
        let candidates = try await discover(urlString: urlString)
        guard let candidate = candidates.first else { throw FollowedSourceError.noFeedCandidates }
        return try await follow(candidate: candidate)
    }

    func discover(urlString: String, requiringItemMembership: Bool = false) async throws -> [SourceCandidateEvidence] {
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
    func failureDiagnostic(for error: Error) -> String {
        let steps = lastDiscoveryTrace.isEmpty ? "none" : lastDiscoveryTrace.joined(separator: " | ")
        return "\(Self.diagnosticCode(for: error)) host=\(lastDiscoveryHost) steps=\(steps)"
    }

    static func diagnosticCode(for error: Error) -> String {
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

    func follow(candidate: SourceCandidateEvidence) async throws -> FeedSubscription {
        guard let url = URL(string: candidate.source.canonicalURL) else { throw FollowedSourceError.invalidURL }
        let parsed = try await fetch(url: url, subscription: nil)
        let host = url.host?.lowercased() ?? candidate.source.host
        let canonical = URL(string: parsed.feedURL ?? url.absoluteString) ?? url
        let sourceId = "source-\(Self.digest(canonical.absoluteString.lowercased()))"
        // Following a feed again keeps its new-item choice (#466).
        let previousPolicy = try repository.loadFeedSubscriptions().first { $0.id == "subscription-\(sourceId)" }?.newItemPolicy
        let subscription = FeedSubscription(
            id: "subscription-\(sourceId)",
            source: SourceIdentity(
                id: sourceId,
                kind: parsed.items.contains(where: { $0.audioURL != nil }) ? .podcastFeed : .articleFeed,
                canonicalURL: canonical.absoluteString,
                host: canonical.host?.lowercased() ?? host,
                title: parsed.title
            ),
            newItemPolicy: previousPolicy
        )
        try repository.saveFeedSubscription(subscription)
        try save(entries: parsed.items, subscription: subscription)
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
    func refreshStale(now: Date = Date(), minimumAge: TimeInterval = 6 * 60 * 60, force: Bool = false) async -> [FeedEntry] {
        var toAdd: [FeedEntry] = []
        for subscription in (try? repository.loadFeedSubscriptions()) ?? [] {
            guard force || subscription.lastRefreshAt.map({ now.timeIntervalSince($0) >= minimumAge }) ?? true else { continue }
            toAdd += await refresh(subscription, now: now)
        }
        return toAdd
    }

    func entries() throws -> [FeedEntry] {
        let muted = Set(try repository.loadFeedSubscriptions().filter { $0.state == .muted }.map(\.id))
        return try repository.loadFeedEntries(subscriptionId: nil)
            .filter { !muted.contains($0.subscriptionId) && $0.state != .dismissed && $0.state != .imported }
            .sorted {
                if $0.publishedAt != $1.publishedAt { return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                return $0.id < $1.id
            }
    }

    func setEntryState(id: String, state: FeedEntryState) throws {
        guard var entry = try repository.loadFeedEntries(subscriptionId: nil).first(where: { $0.id == id }) else { return }
        entry.state = state
        try repository.saveFeedEntry(entry)
    }

    /// An ambiguous enclosure remains a podcast if corroboration fails. Public page metadata
    /// identifies narration without extracting or replacing subscriber feed text.
    func publisherAudioEntry(for entry: FeedEntry) async -> FeedEntry {
        guard entry.publisherNarrationConfirmed != true, entry.publisherPlatform == "substack",
              (entry.bodyWordCount ?? 0) >= PublisherAudioDetector.minimumBodyWords,
              let url = Self.validHTTPSURL(entry.canonicalURL),
              let html = try? await fetchHTML(url: url),
              let confirmed = PublisherNarrationEvidence.confirmedEntry(entry, html: html) else { return entry }
        // A refresh, dismissal or unfollow may finish while the page request awaits. Cache only
        // against the unchanged entry, so corroboration cannot restore a removed/stale row.
        if let current = try? repository.loadFeedEntries(subscriptionId: entry.subscriptionId).first(where: { $0.id == entry.id }),
           current == entry { try? repository.saveFeedEntry(confirmed) }
        return confirmed
    }

    func playableAudioURL(for entry: FeedEntry) async throws -> String? {
        if let audioURL = Self.validHTTPSURL(entry.audioURL) {
            return audioURL.absoluteString
        }
        guard let subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == entry.subscriptionId }),
              subscription.source.kind == .podcastFeed,
              let feedURL = URL(string: subscription.source.canonicalURL) else {
            return nil
        }
        let parsed = try await fetch(url: feedURL, subscription: nil)
        guard let match = parsed.items.first(where: { item in
            item.url == entry.canonicalURL
                || (item.title == entry.title && item.publishedAt == entry.publishedAt)
        }), let audioURL = Self.validHTTPSURL(match.audioURL) else {
            return nil
        }
        var updated = entry
        updated.audioURL = audioURL.absoluteString
        try repository.saveFeedEntry(updated)
        return audioURL.absoluteString
    }

    func setNewItemPolicy(subscriptionId: String, policy: FeedNewItemPolicy) throws {
        guard var subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == subscriptionId }) else { return }
        subscription.newItemPolicy = policy
        try repository.saveFeedSubscription(subscription)
    }

    func setMuted(subscriptionId: String, muted: Bool) throws {
        guard var subscription = try repository.loadFeedSubscriptions().first(where: { $0.id == subscriptionId }) else { return }
        subscription.state = muted ? .muted : .active
        try repository.saveFeedSubscription(subscription)
    }

    func unfollow(subscriptionId: String) throws {
        for entry in try repository.loadFeedEntries(subscriptionId: subscriptionId) where entry.state != .imported {
            try repository.deleteFeedEntry(id: entry.id)
        }
        try repository.deleteFeedSubscription(id: subscriptionId)
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
        var request = URLRequest(url: url)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FollowedSourceError.invalidResponse
        }
        guard data.count <= 1 * 1_024 * 1_024 else { throw FollowedSourceError.htmlResponseTooLarge }
        return String(decoding: data, as: UTF8.self)
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
    private func save(entries: [ParsedFeedItem], subscription: FeedSubscription) throws -> (entries: [FeedEntry], previous: [FeedEntry]) {
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
                episodeGUID: item.guid
            )
            try repository.saveFeedEntry(entry)
            saved.append(entry)
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
