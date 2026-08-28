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
        case .noFeedCandidates: "No RSS, Atom, or JSON Feed was found for this website."
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

    func discover(urlString: String) async throws -> [SourceCandidateEvidence] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw FollowedSourceError.invalidURL }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { throw FollowedSourceError.insecureURL }
        contactedHosts = [host]
        if let parsed = try? await fetch(url: url, subscription: nil) {
            return [candidate(url: url, parsed: parsed, relation: "direct", confidence: 1)]
        }
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
        for (candidateURL, relation, confidence) in evidence.prefix(8) {
            guard let parsed = try? await fetch(url: candidateURL, subscription: nil) else { continue }
            candidates.append(candidate(url: candidateURL, parsed: parsed, relation: relation, confidence: confidence))
        }
        guard !candidates.isEmpty else { throw FollowedSourceError.noFeedCandidates }
        return candidates
    }

    func follow(candidate: SourceCandidateEvidence) async throws -> FeedSubscription {
        guard let url = URL(string: candidate.source.canonicalURL) else { throw FollowedSourceError.invalidURL }
        let parsed = try await fetch(url: url, subscription: nil)
        let host = url.host?.lowercased() ?? candidate.source.host
        let canonical = URL(string: parsed.feedURL ?? url.absoluteString) ?? url
        let sourceId = "source-\(Self.digest(canonical.absoluteString.lowercased()))"
        let subscription = FeedSubscription(
            id: "subscription-\(sourceId)",
            source: SourceIdentity(
                id: sourceId,
                kind: parsed.items.contains(where: { $0.audioURL != nil }) ? .podcastFeed : .articleFeed,
                canonicalURL: canonical.absoluteString,
                host: canonical.host?.lowercased() ?? host,
                title: parsed.title
            )
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

    func refreshStale(now: Date = Date(), minimumAge: TimeInterval = 6 * 60 * 60, force: Bool = false) async {
        for subscription in (try? repository.loadFeedSubscriptions()) ?? [] {
            guard force || subscription.lastRefreshAt.map({ now.timeIntervalSince($0) >= minimumAge }) ?? true else { continue }
            await refresh(subscription, now: now)
        }
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

    private func refresh(_ original: FeedSubscription, now: Date) async {
        var subscription = original
        do {
            let parsed = try await fetch(url: URL(string: subscription.source.canonicalURL)!, subscription: subscription)
            try save(entries: parsed.items, subscription: subscription)
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
        return try parser.parse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
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

    private func save(entries: [ParsedFeedItem], subscription: FeedSubscription) throws {
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

        for item in retainedItems {
            let id = Self.entryID(subscriptionID: subscription.id, itemID: item.id)
            try repository.saveFeedEntry(FeedEntry(
                id: id,
                subscriptionId: subscription.id,
                canonicalURL: item.url,
                title: item.title,
                author: item.author,
                summary: item.summary,
                publishedAt: item.publishedAt,
                state: existing[id]?.state ?? .unseen
            ))
        }

        for entry in existingEntries where !retainedIDs.contains(entry.id) {
            // Imported and dismissed entries are suppression tombstones, not Quick Add
            // suggestions. Keep them so an older episode cannot reappear later.
            guard entry.state == .unseen || entry.state == .seen else { continue }
            try repository.deleteFeedEntry(id: entry.id)
        }
    }

    private static func entryID(subscriptionID: String, itemID: String) -> String {
        "entry-\(digest(subscriptionID + "\u{1f}" + itemID))"
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
