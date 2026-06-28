import Foundation
import SessionKit

struct PublicPodcastLinkResolver: LinkResolutionClient, Sendable {
    typealias Fetch = @Sendable (URL) throws -> Data

    private let fetch: Fetch

    init(fetch: @escaping Fetch = PublicPodcastLinkResolver.fetchSynchronously) {
        self.fetch = fetch
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        let trimmed = request.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return unsupported(request: request, reason: "invalid_url")
        }

        if isDirectAudioURL(url) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "direct_audio", title: title(from: url), role: "audio_file"),
                title: title(from: url),
                audioURL: url.absoluteString,
                confidence: 1
            )
            return playable(request: request, provider: "direct_audio", candidate: candidate)
        }

        if isApplePodcastsURL(url), let result = try resolveApplePodcastsURL(url, request: request) {
            return result
        }

        if looksLikeRSSURL(url), let result = try resolveRSSFeed(url, request: request, expectedTitle: nil, expectedURL: nil) {
            return result
        }

        if isSpotifyURL(url) {
            return try metadataOnlyResult(request: request, url: url, provider: "spotify", reason: "spotify_audio_requires_provider_playback")
        }

        if let result = try resolveRSSFeed(url, request: request, expectedTitle: nil, expectedURL: nil) {
            return result
        }

        return try metadataOnlyResult(request: request, url: url, provider: url.host, reason: "audio_enclosure_not_found")
    }

    func resolveAsync(
        _ request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval = 8,
        overallTimeoutSeconds: TimeInterval = 20
    ) async throws -> LinkResolutionResult {
        try await withThrowingTaskGroup(of: LinkResolutionResult.self) { group in
            group.addTask {
                try await resolveAsyncBody(request, requestTimeoutSeconds: requestTimeoutSeconds)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(overallTimeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func resolveAsyncBody(
        _ request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult {
        let trimmed = request.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return unsupported(request: request, reason: "invalid_url")
        }

        if isDirectAudioURL(url) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "direct_audio", title: title(from: url), role: "audio_file"),
                title: title(from: url),
                audioURL: url.absoluteString,
                confidence: 1
            )
            return playable(request: request, provider: "direct_audio", candidate: candidate)
        }

        if isApplePodcastsURL(url), let result = try await resolveApplePodcastsURLAsync(url, request: request, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }

        if looksLikeRSSURL(url), let result = try await resolveRSSFeedAsync(url, request: request, expectedTitle: nil, expectedURL: nil, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }

        if isSpotifyURL(url) {
            return try await metadataOnlyResultAsync(request: request, url: url, provider: "spotify", reason: "spotify_audio_requires_provider_playback", requestTimeoutSeconds: requestTimeoutSeconds)
        }

        if let result = try await resolveRSSFeedAsync(url, request: request, expectedTitle: nil, expectedURL: nil, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }

        return try await metadataOnlyResultAsync(request: request, url: url, provider: url.host, reason: "audio_enclosure_not_found", requestTimeoutSeconds: requestTimeoutSeconds)
    }

    private func resolveApplePodcastsURL(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        if let episodeId = queryValue("i", in: url),
           let lookupResult = try resolveAppleLookup(episodeId: episodeId, url: url, request: request) {
            return lookupResult
        }

        if let pageResult = try resolveApplePage(url, request: request) {
            return pageResult
        }

        let reason = queryValue("i", in: url) == nil ? "apple_episode_id_missing" : "apple_lookup_empty"
        return needsReview(request: request, provider: "apple_podcasts", title: title(from: url), reason: reason)
    }

    private func resolveApplePodcastsURLAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        if let episodeId = queryValue("i", in: url),
           let lookupResult = try await resolveAppleLookupAsync(episodeId: episodeId, url: url, request: request, requestTimeoutSeconds: requestTimeoutSeconds) {
            return lookupResult
        }

        if let pageResult = try await resolveApplePageAsync(url, request: request, requestTimeoutSeconds: requestTimeoutSeconds) {
            return pageResult
        }

        let reason = queryValue("i", in: url) == nil ? "apple_episode_id_missing" : "apple_lookup_empty"
        return needsReview(request: request, provider: "apple_podcasts", title: title(from: url), reason: reason)
    }

    private func resolveAppleLookup(episodeId: String, url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(episodeId)&entity=podcastEpisode")!
        guard let data = try? fetch(lookupURL) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let episode = results.first(where: { ($0["wrapperType"] as? String) == "podcastEpisode" || ($0["kind"] as? String) == "podcast-episode" }) ?? results.first else {
            return nil
        }
        let title = episode["trackName"] as? String ?? episode["collectionName"] as? String
        if let episodeURL = episode["episodeUrl"] as? String,
           let audioURL = URL(string: episodeURL),
           isHTTPURL(audioURL) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "apple_podcasts", title: title, role: "discovery"),
                title: title ?? "Apple Podcasts Episode",
                showTitle: episode["collectionName"] as? String,
                audioURL: episodeURL,
                confidence: 0.95
            )
            return playable(request: request, provider: "apple_podcasts", candidate: candidate)
        }
        if let feedURLString = episode["feedUrl"] as? String,
           let feedURL = URL(string: feedURLString),
           let result = try resolveRSSFeed(feedURL, request: request, expectedTitle: title, expectedURL: url.absoluteString) {
            return result
        }
        return nil
    }

    private func resolveAppleLookupAsync(
        episodeId: String,
        url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(episodeId)&entity=podcastEpisode")!
        guard let data = try? await fetchAsync(lookupURL, timeout: requestTimeoutSeconds) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let episode = results.first(where: { ($0["wrapperType"] as? String) == "podcastEpisode" || ($0["kind"] as? String) == "podcast-episode" }) ?? results.first else {
            return nil
        }
        let title = episode["trackName"] as? String ?? episode["collectionName"] as? String
        if let episodeURL = episode["episodeUrl"] as? String,
           let audioURL = URL(string: episodeURL),
           isHTTPURL(audioURL) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "apple_podcasts", title: title, role: "discovery"),
                title: title ?? "Apple Podcasts Episode",
                showTitle: episode["collectionName"] as? String,
                audioURL: episodeURL,
                confidence: 0.95
            )
            return playable(request: request, provider: "apple_podcasts", candidate: candidate)
        }
        if let feedURLString = episode["feedUrl"] as? String,
           let feedURL = URL(string: feedURLString),
           let result = try await resolveRSSFeedAsync(feedURL, request: request, expectedTitle: title, expectedURL: url.absoluteString, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }
        return nil
    }

    private func resolveApplePage(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        guard let data = try? fetch(url),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let pageTitle = htmlTitle(html)?.replacingOccurrences(of: " - Apple Podcasts", with: "") ?? title(from: url)
        if let streamURL = jsonStringValue(named: "streamUrl", in: html),
           let audioURL = URL(string: streamURL),
           isHTTPURL(audioURL) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "apple_podcasts", title: pageTitle, role: "discovery"),
                title: jsonStringValue(named: "title", in: html) ?? pageTitle,
                showTitle: jsonStringValue(named: "collectionName", in: html) ?? jsonStringValue(named: "showTitle", in: html),
                durationMs: jsonNumberValue(named: "duration", in: html).map { max(0, $0 * 1000) },
                audioURL: streamURL,
                confidence: 0.78
            )
            return playable(request: request, provider: "apple_podcasts", candidate: candidate)
        }
        if let feedURLString = jsonStringValue(named: "feedUrl", in: html),
           let feedURL = URL(string: feedURLString),
           let result = try resolveRSSFeed(feedURL, request: request, expectedTitle: pageTitle, expectedURL: url.absoluteString) {
            return result
        }
        return needsReview(request: request, provider: "apple_podcasts", title: pageTitle, reason: "apple_audio_enclosure_not_found")
    }

    private func resolveApplePageAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        guard let data = try? await fetchAsync(url, timeout: requestTimeoutSeconds),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let pageTitle = htmlTitle(html)?.replacingOccurrences(of: " - Apple Podcasts", with: "") ?? title(from: url)
        if let streamURL = jsonStringValue(named: "streamUrl", in: html),
           let audioURL = URL(string: streamURL),
           isHTTPURL(audioURL) {
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: url.absoluteString, provider: "apple_podcasts", title: pageTitle, role: "discovery"),
                title: jsonStringValue(named: "title", in: html) ?? pageTitle,
                showTitle: jsonStringValue(named: "collectionName", in: html) ?? jsonStringValue(named: "showTitle", in: html),
                durationMs: jsonNumberValue(named: "duration", in: html).map { max(0, $0 * 1000) },
                audioURL: streamURL,
                confidence: 0.78
            )
            return playable(request: request, provider: "apple_podcasts", candidate: candidate)
        }
        if let feedURLString = jsonStringValue(named: "feedUrl", in: html),
           let feedURL = URL(string: feedURLString),
           let result = try await resolveRSSFeedAsync(feedURL, request: request, expectedTitle: pageTitle, expectedURL: url.absoluteString, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }
        return needsReview(request: request, provider: "apple_podcasts", title: pageTitle, reason: "apple_audio_enclosure_not_found")
    }

    private func resolveRSSFeed(_ url: URL, request: LinkResolutionRequest, expectedTitle: String?, expectedURL: String?) throws -> LinkResolutionResult? {
        let data = try fetch(url)
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<rss", options: [.caseInsensitive]) != nil ||
              text.range(of: "<feed", options: [.caseInsensitive]) != nil else {
            return nil
        }
        let parser = RSSFeedParser()
        let items = parser.parse(data: data)
        guard !items.isEmpty else {
            return needsReview(request: request, provider: "rss", title: expectedTitle ?? title(from: url), reason: "rss_feed_empty")
        }
        guard let selected = selectRSSItem(items, expectedTitle: expectedTitle, expectedURL: expectedURL ?? request.inputURL) else {
            return needsReview(request: request, provider: "rss", title: expectedTitle ?? title(from: url), reason: "rss_episode_ambiguous")
        }
        guard let audioURL = selected.enclosureURL, !audioURL.isEmpty else {
            return needsReview(request: request, provider: "rss", title: selected.title ?? expectedTitle ?? title(from: url), reason: "rss_audio_enclosure_missing")
        }
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: url.absoluteString, provider: "rss", title: selected.feedTitle, role: "canonical_feed"),
            title: selected.title ?? expectedTitle ?? title(from: url),
            showTitle: selected.feedTitle,
            durationMs: selected.durationMs,
            publishedAt: selected.publishedAt,
            audioURL: audioURL,
            transcriptLinks: selected.transcriptLinks,
            confidence: selected.isExactMatch ? 0.96 : 0.82
        )
        return playable(request: request, provider: "rss", candidate: candidate)
    }

    private func resolveRSSFeedAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        expectedTitle: String?,
        expectedURL: String?,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        let data = try await fetchAsync(url, timeout: requestTimeoutSeconds)
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<rss", options: [.caseInsensitive]) != nil ||
              text.range(of: "<feed", options: [.caseInsensitive]) != nil else {
            return nil
        }
        let parser = RSSFeedParser()
        let items = parser.parse(data: data)
        guard !items.isEmpty else {
            return needsReview(request: request, provider: "rss", title: expectedTitle ?? title(from: url), reason: "rss_feed_empty")
        }
        guard let selected = selectRSSItem(items, expectedTitle: expectedTitle, expectedURL: expectedURL ?? request.inputURL) else {
            return needsReview(request: request, provider: "rss", title: expectedTitle ?? title(from: url), reason: "rss_episode_ambiguous")
        }
        guard let audioURL = selected.enclosureURL, !audioURL.isEmpty else {
            return needsReview(request: request, provider: "rss", title: selected.title ?? expectedTitle ?? title(from: url), reason: "rss_audio_enclosure_missing")
        }
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: url.absoluteString, provider: "rss", title: selected.feedTitle, role: "canonical_feed"),
            title: selected.title ?? expectedTitle ?? title(from: url),
            showTitle: selected.feedTitle,
            durationMs: selected.durationMs,
            publishedAt: selected.publishedAt,
            audioURL: audioURL,
            transcriptLinks: selected.transcriptLinks,
            confidence: selected.isExactMatch ? 0.96 : 0.82
        )
        return playable(request: request, provider: "rss", candidate: candidate)
    }

    private func selectRSSItem(_ items: [RSSFeedItem], expectedTitle: String?, expectedURL: String?) -> RSSFeedItem? {
        if let expectedURL, !expectedURL.isEmpty {
            let normalized = expectedURL.lowercased()
            if let match = items.first(where: { item in
                [item.link, item.guid].compactMap { $0?.lowercased() }.contains { value in
                    value == normalized || value.contains(normalized) || normalized.contains(value)
                }
            }) {
                var exact = match
                exact.isExactMatch = true
                return exact
            }
        }
        if let expectedTitle, !expectedTitle.isEmpty {
            let normalized = normalize(expectedTitle)
            if let match = items.first(where: { normalize($0.title ?? "") == normalized }) {
                var exact = match
                exact.isExactMatch = true
                return exact
            }
        }
        if items.count == 1 {
            return items[0]
        }
        return items.first(where: { $0.enclosureURL != nil })
    }

    private func metadataOnlyResult(request: LinkResolutionRequest, url: URL, provider: String?, reason: String) throws -> LinkResolutionResult {
        let data = try? fetch(url)
        let pageTitle = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(htmlTitle)
        return needsReview(request: request, provider: provider, title: pageTitle ?? title(from: url), reason: reason)
    }

    private func metadataOnlyResultAsync(
        request: LinkResolutionRequest,
        url: URL,
        provider: String?,
        reason: String,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult {
        let data = try? await fetchAsync(url, timeout: requestTimeoutSeconds)
        let pageTitle = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(htmlTitle)
        return needsReview(request: request, provider: provider, title: pageTitle ?? title(from: url), reason: reason)
    }

    private func playable(request: LinkResolutionRequest, provider: String, candidate: LinkResolutionCandidate) -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: provider, role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        )
    }

    private func needsReview(request: LinkResolutionRequest, provider: String?, title: String, reason: String) -> LinkResolutionResult {
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: request.inputURL, provider: provider, title: title, role: "discovery"),
            title: title,
            confidence: 0.3
        )
        return LinkResolutionResult(
            requestId: request.id,
            status: .needsReview,
            originalLink: SourceLink(url: request.inputURL, provider: provider, title: title, role: "discovery"),
            selectedCandidate: nil,
            candidates: [candidate],
            failureReason: reason
        )
    }

    private func unsupported(request: LinkResolutionRequest, reason: String) -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .unsupported,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            failureReason: reason
        )
    }

    private func isDirectAudioURL(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus"].contains(url.pathExtension.lowercased())
    }

    private func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    private func looksLikeRSSURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("rss") || lower.contains("feed") || lower.hasSuffix(".xml")
    }

    private func isApplePodcastsURL(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().contains("podcasts.apple.com")
    }

    private func isSpotifyURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("spotify.com") && url.path.lowercased().contains("/episode/")
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func title(from url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        if !last.isEmpty, last != "/" {
            return last.replacingOccurrences(of: "-", with: " ")
        }
        return url.host ?? "Shared Audio"
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func htmlTitle(_ html: String) -> String? {
        if let og = metaContent(named: "og:title", in: html) {
            return og
        }
        guard let start = html.range(of: "<title", options: [.caseInsensitive]),
              let closeStart = html[start.upperBound...].range(of: ">", options: [.caseInsensitive]),
              let end = html[closeStart.upperBound...].range(of: "</title>", options: [.caseInsensitive]) else {
            return nil
        }
        return String(html[closeStart.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metaContent(named name: String, in html: String) -> String? {
        let pattern = #"<meta\s+[^>]*(?:property|name)=["']\#(NSRegularExpression.escapedPattern(for: name))["'][^>]*content=["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jsonStringValue(named name: String, in text: String) -> String? {
        let pattern = #""\#(NSRegularExpression.escapedPattern(for: name))"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let escaped = String(text[valueRange])
        let quoted = "\"\(escaped)\""
        return (try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))) ?? escaped
    }

    private func jsonNumberValue(named name: String, in text: String) -> Int? {
        let pattern = #""\#(NSRegularExpression.escapedPattern(for: name))"\s*:\s*([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func fetchSynchronously(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResultBox<Data>()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.set(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status), let data else {
                result.set(.failure(URLError(.badServerResponse)))
                return
            }
            result.set(.success(data))
        }.resume()
        semaphore.wait()
        return try result.get().get()
    }

    private func fetchAsync(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private final class LockedResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ next: Result<Value, Error>) {
        lock.lock()
        value = next
        lock.unlock()
    }

    func get() throws -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let value else {
            throw URLError(.unknown)
        }
        return value
    }
}

private struct RSSFeedItem {
    var feedTitle: String?
    var title: String?
    var link: String?
    var guid: String?
    var enclosureURL: String?
    var transcriptLinks: [SourceTranscriptLink] = []
    var publishedAt: String?
    var durationMs: Int?
    var isExactMatch = false
}

private final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var items: [RSSFeedItem] = []
    private var feedTitle: String?
    private var currentItem: RSSFeedItem?
    private var currentElement = ""
    private var currentText = ""
    private var isInItem = false

    func parse(data: Data) -> [RSSFeedItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = localName(elementName)
        currentElement = element
        currentText = ""
        if element == "item" || element == "entry" {
            isInItem = true
            currentItem = RSSFeedItem(feedTitle: feedTitle)
        } else if isInItem, element == "enclosure" {
            currentItem?.enclosureURL = attributeDict["url"]
        } else if isInItem, element == "link", let href = attributeDict["href"], currentItem?.link == nil {
            currentItem?.link = href
        } else if isInItem, element == "transcript" {
            appendTranscriptLink(attributes: attributeDict)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInItem {
            switch element {
            case "title":
                currentItem?.title = text
            case "link":
                if currentItem?.link == nil { currentItem?.link = text }
            case "guid", "id":
                currentItem?.guid = text
            case "pubdate", "published", "updated":
                currentItem?.publishedAt = text
            case "duration":
                currentItem?.durationMs = parseDurationMs(text)
            case "item", "entry":
                if var item = currentItem {
                    item.feedTitle = item.feedTitle ?? feedTitle
                    items.append(item)
                }
                currentItem = nil
                isInItem = false
            default:
                break
            }
        } else if element == "title", feedTitle == nil {
            feedTitle = text
        }
        currentText = ""
    }

    private func parseDurationMs(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 {
            return ((parts[0] * 3600) + (parts[1] * 60) + parts[2]) * 1000
        }
        if parts.count == 2 {
            return ((parts[0] * 60) + parts[1]) * 1000
        }
        if parts.count == 1 {
            return parts[0] * 1000
        }
        return nil
    }

    private func appendTranscriptLink(attributes: [String: String]) {
        let normalized = Dictionary(uniqueKeysWithValues: attributes.map { key, value in
            (key.lowercased(), value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        guard let url = normalized["url"], !url.isEmpty else { return }
        let type = normalized["type"] ?? normalized["mime-type"] ?? normalized["mimetype"] ?? ""
        guard !type.isEmpty else { return }
        currentItem?.transcriptLinks.append(SourceTranscriptLink(
            url: url,
            type: type,
            language: normalized["language"] ?? normalized["lang"],
            rel: normalized["rel"]
        ))
    }

    private func localName(_ elementName: String) -> String {
        (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
    }
}
