import Foundation
import SessionKit

struct PublicPodcastLinkResolver: LinkResolutionClient, Sendable {
    typealias Fetch = @Sendable (URL) throws -> Data

    private struct EpisodeEvidence {
        var title: String
        var showTitle: String?
        var publisher: String?
        var publishedAt: String?
        var durationMs: Int?
    }

    private struct ScoredAppleCandidate {
        var candidate: LinkResolutionCandidate
        var score: Double
        var hasConflictingShowEvidence: Bool
    }

    private struct EpisodePageMetadata {
        var title: String
        var showTitle: String?
        var durationMs: Int?
        var publishedAt: String?
        var audioURL: String
        var transcriptLinks: [SourceTranscriptLink]
        var chapterLinks: [SourceChapterLink]
    }

    private let fetch: Fetch

    init(fetch: @escaping Fetch = PublicPodcastLinkResolver.fetchSynchronously) {
        self.fetch = fetch
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        let trimmed = request.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
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

        if isSpotifyHostURL(url), !isSpotifyURL(url) {
            return needsReview(
                request: request,
                provider: "spotify",
                title: "Spotify podcast",
                reason: "spotify_specific_episode_required"
            )
        }

        if isSpotifyURL(url) {
            return try resolveSpotifyURL(url, request: request)
        }

        if let result = try resolveRSSFeed(url, request: request, expectedTitle: nil, expectedURL: nil) {
            return result
        }

        if let result = try resolveEpisodePage(url, request: request) {
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
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
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

        if isSpotifyHostURL(url), !isSpotifyURL(url) {
            return needsReview(
                request: request,
                provider: "spotify",
                title: "Spotify podcast",
                reason: "spotify_specific_episode_required"
            )
        }

        if isSpotifyURL(url) {
            return try await resolveSpotifyURLAsync(
                url,
                request: request,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
        }

        if let result = try await resolveRSSFeedAsync(url, request: request, expectedTitle: nil, expectedURL: nil, requestTimeoutSeconds: requestTimeoutSeconds) {
            return result
        }

        if let result = try await resolveEpisodePageAsync(
            url,
            request: request,
            requestTimeoutSeconds: requestTimeoutSeconds
        ) {
            return result
        }

        return try await metadataOnlyResultAsync(request: request, url: url, provider: url.host, reason: "audio_enclosure_not_found", requestTimeoutSeconds: requestTimeoutSeconds)
    }

    private func resolveApplePodcastsURL(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        let lookupResult: LinkResolutionResult?
        if let episodeId = queryValue("i", in: url),
           let showId = appleShowId(in: url) {
            lookupResult = try resolveAppleLookup(showId: showId, episodeId: episodeId, url: url, request: request)
        } else {
            lookupResult = nil
        }
        if let lookupResult, lookupResult.status == .playable {
            return lookupResult
        }

        let pageResult = try resolveApplePage(url, request: request)
        if let pageResult, pageResult.status == .playable {
            return pageResult
        }
        if let lookupResult {
            return lookupResult
        }
        if let pageResult {
            return pageResult
        }

        let reason = queryValue("i", in: url) == nil ? "apple_episode_id_missing" : "apple_lookup_empty"
        return needsReview(request: request, provider: "apple_podcasts", title: title(from: url), reason: reason)
    }

    private func resolveSpotifyURL(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult {
        let oEmbedData = try? fetch(spotifyOEmbedURL(for: url))
        let pageData = try? fetch(spotifyEmbedURL(for: url))
        guard let evidence = spotifyEpisodeEvidence(oEmbedData: oEmbedData, pageData: pageData) else {
            return needsReview(
                request: request,
                provider: "spotify",
                title: title(from: url),
                reason: "spotify_metadata_unavailable"
            )
        }
        var accumulatedResults: [[String: Any]] = []
        var lastResult: LinkResolutionResult?
        for searchTerm in spotifyAppleSearchTerms(title: evidence.title) {
            guard let searchData = try? fetch(appleEpisodeSearchURL(title: searchTerm)),
                  let results = appleSearchResults(from: searchData) else {
                continue
            }
            accumulatedResults = mergingAppleSearchResults(accumulatedResults, with: results)
            let result = spotifyAppleMatchResult(
                request: request,
                spotifyURL: url,
                evidence: evidence,
                results: accumulatedResults
            )
            if result.status == .playable {
                return result
            }
            lastResult = result
        }
        return lastResult ?? needsReview(
            request: request,
            provider: "spotify",
            title: evidence.title,
            reason: "spotify_episode_not_found_on_apple"
        )
    }

    private func resolveSpotifyURLAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult {
        let oEmbedData = try? await fetchAsync(spotifyOEmbedURL(for: url), timeout: requestTimeoutSeconds)
        let pageData = try? await fetchAsync(spotifyEmbedURL(for: url), timeout: requestTimeoutSeconds)
        guard let evidence = spotifyEpisodeEvidence(oEmbedData: oEmbedData, pageData: pageData) else {
            return needsReview(
                request: request,
                provider: "spotify",
                title: title(from: url),
                reason: "spotify_metadata_unavailable"
            )
        }
        var accumulatedResults: [[String: Any]] = []
        var lastResult: LinkResolutionResult?
        for searchTerm in spotifyAppleSearchTerms(title: evidence.title) {
            guard let searchData = try? await fetchAsync(
                appleEpisodeSearchURL(title: searchTerm),
                timeout: requestTimeoutSeconds
            ), let results = appleSearchResults(from: searchData) else {
                continue
            }
            accumulatedResults = mergingAppleSearchResults(accumulatedResults, with: results)
            let result = spotifyAppleMatchResult(
                request: request,
                spotifyURL: url,
                evidence: evidence,
                results: accumulatedResults
            )
            if result.status == .playable {
                return result
            }
            lastResult = result
        }
        return lastResult ?? needsReview(
            request: request,
            provider: "spotify",
            title: evidence.title,
            reason: "spotify_episode_not_found_on_apple"
        )
    }

    private func spotifyAppleMatchResult(
        request: LinkResolutionRequest,
        spotifyURL: URL,
        evidence: EpisodeEvidence,
        results: [[String: Any]]
    ) -> LinkResolutionResult {
        let playableEpisodes = results.filter { result in
            let isEpisode = (result["wrapperType"] as? String) == "podcastEpisode"
                || (result["kind"] as? String) == "podcast-episode"
            guard isEpisode,
                  let audioURLString = result["episodeUrl"] as? String,
                  let audioURL = URL(string: audioURLString),
                  isHTTPURL(audioURL) else {
                return false
            }
            return true
        }
        var scored = playableEpisodes.compactMap { episode -> ScoredAppleCandidate? in
            scoreAppleEpisode(episode, against: evidence, spotifyURL: spotifyURL)
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.candidate.title < rhs.candidate.title }
            return lhs.score > rhs.score
        }
        if scored.count == 1, !scored[0].hasConflictingShowEvidence {
            scored[0].score = min(1, scored[0].score + 0.18)
            scored[0].candidate.confidence = scored[0].score
        }
        guard let best = scored.first else {
            return needsReview(
                request: request,
                provider: "spotify",
                title: evidence.title,
                reason: "spotify_episode_not_found_on_apple"
            )
        }
        let runnerUp = scored.dropFirst().first?.score ?? 0
        if best.score >= 0.78,
           best.score - runnerUp >= 0.08,
           !best.hasConflictingShowEvidence {
            return playable(request: request, provider: "spotify", candidate: best.candidate)
        }
        return review(
            request: request,
            provider: "spotify",
            title: evidence.title,
            reason: "spotify_episode_match_ambiguous",
            candidates: Array(scored.prefix(5).map(\.candidate))
        )
    }

    private func scoreAppleEpisode(
        _ episode: [String: Any],
        against evidence: EpisodeEvidence,
        spotifyURL: URL
    ) -> ScoredAppleCandidate? {
        let title = episode["trackName"] as? String ?? ""
        let titleScore = episodeTitleSimilarity(evidence.title, title)
        guard titleScore >= 0.55,
              let audioURL = episode["episodeUrl"] as? String else { return nil }
        let showTitle = episode["collectionName"] as? String
        let publishedAt = episode["releaseDate"] as? String
        let durationMs = (episode["trackTimeMillis"] as? NSNumber)?.intValue
        let publisher = episode["artistName"] as? String
        var score = 0.62 * titleScore
        var hasConflictingShowEvidence = false
        if let expected = evidence.showTitle, let showTitle {
            let showScore = textSimilarity(expected, showTitle)
            score += 0.18 * showScore
            hasConflictingShowEvidence = showScore < 0.35
        }
        if let expected = evidence.publisher, let publisher {
            score += 0.04 * textSimilarity(expected, publisher)
        }
        score += dateScore(evidence.publishedAt, publishedAt) * 0.08
        score += durationScore(evidence.durationMs, durationMs) * 0.08
        score = min(1, score)
        let appleURL = (episode["trackViewUrl"] as? String).flatMap(URL.init(string:))
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(
                url: appleURL?.absoluteString ?? spotifyURL.absoluteString,
                provider: "apple_podcasts",
                title: showTitle,
                role: "canonical_source"
            ),
            title: title.isEmpty ? evidence.title : title,
            showTitle: showTitle,
            durationMs: durationMs,
            publishedAt: publishedAt,
            audioURL: audioURL,
            confidence: score
        )
        return ScoredAppleCandidate(
            candidate: candidate,
            score: score,
            hasConflictingShowEvidence: hasConflictingShowEvidence
        )
    }

    private func spotifyOEmbedURL(for url: URL) -> URL {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url!
    }

    private func spotifyEmbedURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !components.path.lowercased().hasPrefix("/embed/") {
            components.path = "/embed" + components.path
        }
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private func appleEpisodeSearchURL(title: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: "25")
        ]
        return components.url!
    }

    private func spotifyAppleSearchTerms(title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutEpisodeNumber = removingLeadingEpisodeNumber(from: trimmed)
        if normalize(trimmed) == normalize(withoutEpisodeNumber) {
            return [trimmed]
        }
        return [trimmed, withoutEpisodeNumber]
    }

    private func removingLeadingEpisodeNumber(from title: String) -> String {
        let pattern = #"^\s*(?:(?:episode|ep\.?)\s*)?#?\d{1,6}\s*[.:\-–—]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let stripped = regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? title : stripped
    }

    private func spotifyEpisodeEvidence(oEmbedData: Data?, pageData: Data?) -> EpisodeEvidence? {
        var object: [String: Any] = [:]
        if let oEmbedData,
           let decoded = try? JSONSerialization.jsonObject(with: oEmbedData) as? [String: Any] {
            object = decoded
        }
        let html = pageData.flatMap { String(data: $0, encoding: .utf8) }
        let embeddedEntity = html.flatMap(spotifyEmbeddedEntity)
        let rawTitle = (object["title"] as? String)
            ?? (embeddedEntity?["title"] as? String)
            ?? (embeddedEntity?["name"] as? String)
            ?? html.flatMap(htmlTitle)
        guard let rawTitle else { return nil }
        let title = rawTitle
            .replacingOccurrences(of: " | Podcast on Spotify", with: "")
            .replacingOccurrences(of: " - song and lyrics by", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let showTitle = (object["showTitle"] as? String)
            ?? (object["podcastName"] as? String)
            ?? (embeddedEntity?["subtitle"] as? String)
            ?? html.flatMap { jsonStringValue(named: "showName", in: $0) }
            ?? html.flatMap { jsonStringValue(named: "podcastName", in: $0) }
        let publisher = (object["publisher"] as? String)
            ?? html.flatMap { jsonStringValue(named: "publisher", in: $0) }
        let publishedAt = (object["releaseDate"] as? String)
            ?? (object["datePublished"] as? String)
            ?? ((embeddedEntity?["releaseDate"] as? [String: Any])?["isoString"] as? String)
            ?? html.flatMap { jsonStringValue(named: "releaseDate", in: $0) }
            ?? html.flatMap { jsonStringValue(named: "datePublished", in: $0) }
        let objectDuration = (object["durationMs"] as? NSNumber)?.intValue
            ?? (object["duration"] as? NSNumber).map { normalizedDurationMs($0.intValue) }
        let pageDuration = (embeddedEntity?["duration"] as? NSNumber)?.intValue
            ?? html.flatMap { jsonNumberValue(named: "durationMs", in: $0) }
            ?? html.flatMap { jsonNumberValue(named: "duration", in: $0) }.map(normalizedDurationMs)
        return EpisodeEvidence(
            title: title,
            showTitle: showTitle,
            publisher: publisher,
            publishedAt: publishedAt,
            durationMs: objectDuration ?? pageDuration
        )
    }

    private func spotifyEmbeddedEntity(in html: String) -> [String: Any]? {
        let marker = #"<script id="__NEXT_DATA__" type="application/json">"#
        guard let markerRange = html.range(of: marker, options: [.caseInsensitive]),
              let endRange = html[markerRange.upperBound...].range(of: "</script>", options: [.caseInsensitive]) else {
            return nil
        }
        let json = String(html[markerRange.upperBound..<endRange.lowerBound])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let dataObject = state["data"] as? [String: Any] else {
            return nil
        }
        return dataObject["entity"] as? [String: Any]
    }

    private func normalizedDurationMs(_ value: Int) -> Int {
        value > 100_000 ? value : max(0, value * 1_000)
    }

    private func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalize(lhs).split(separator: " ").map(String.init))
        let right = Set(normalize(rhs).split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private func episodeTitleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        max(
            textSimilarity(lhs, rhs),
            textSimilarity(removingLeadingEpisodeNumber(from: lhs), removingLeadingEpisodeNumber(from: rhs))
        )
    }

    private func dateScore(_ lhs: String?, _ rhs: String?) -> Double {
        guard let lhs, let rhs,
              let left = ISO8601DateFormatter().date(from: lhs),
              let right = ISO8601DateFormatter().date(from: rhs) else { return 0 }
        let days = abs(left.timeIntervalSince(right)) / 86_400
        if days <= 1 { return 1 }
        if days <= 7 { return 0.65 }
        if days <= 31 { return 0.25 }
        return 0
    }

    private func durationScore(_ lhs: Int?, _ rhs: Int?) -> Double {
        guard let lhs, let rhs, lhs > 0, rhs > 0 else { return 0 }
        let difference = abs(lhs - rhs)
        if difference <= 2_000 { return 1 }
        if difference <= 30_000 { return 0.7 }
        if difference <= 120_000 { return 0.25 }
        return 0
    }

    private func appleSearchResults(from data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["results"] as? [[String: Any]]
    }

    private func mergingAppleSearchResults(
        _ existing: [[String: Any]],
        with incoming: [[String: Any]]
    ) -> [[String: Any]] {
        var merged = existing
        var identities = Set(existing.compactMap(appleSearchResultIdentity))
        for result in incoming {
            guard let identity = appleSearchResultIdentity(result) else {
                merged.append(result)
                continue
            }
            if identities.insert(identity).inserted {
                merged.append(result)
            }
        }
        return merged
    }

    private func appleSearchResultIdentity(_ result: [String: Any]) -> String? {
        if let trackId = result["trackId"] as? NSNumber {
            return "track:\(trackId.stringValue)"
        }
        if let trackId = result["trackId"] as? String {
            return "track:\(trackId)"
        }
        if let episodeURL = result["episodeUrl"] as? String {
            return "audio:\(episodeURL)"
        }
        return nil
    }

    private func resolveApplePodcastsURLAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        let lookupResult: LinkResolutionResult?
        if let episodeId = queryValue("i", in: url),
           let showId = appleShowId(in: url) {
            lookupResult = try await resolveAppleLookupAsync(
                showId: showId,
                episodeId: episodeId,
                url: url,
                request: request,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
        } else {
            lookupResult = nil
        }
        if let lookupResult, lookupResult.status == .playable {
            return lookupResult
        }

        let pageResult = try await resolveApplePageAsync(
            url,
            request: request,
            requestTimeoutSeconds: requestTimeoutSeconds
        )
        if let pageResult, pageResult.status == .playable {
            return pageResult
        }
        if let lookupResult {
            return lookupResult
        }
        if let pageResult {
            return pageResult
        }

        let reason = queryValue("i", in: url) == nil ? "apple_episode_id_missing" : "apple_lookup_empty"
        return needsReview(request: request, provider: "apple_podcasts", title: title(from: url), reason: reason)
    }

    private func resolveAppleLookup(showId: String, episodeId: String, url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        let lookupURL = appleLookupURL(showId: showId)
        guard let data = try? fetch(lookupURL) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            return nil
        }
        guard let episode = appleEpisode(id: episodeId, in: results) else {
            if let feedURL = appleFeedURL(in: results) {
                return try resolveRSSFeed(
                    feedURL,
                    request: request,
                    expectedTitle: appleEpisodeTitleHint(in: url),
                    expectedURL: url.absoluteString
                )
            }
            return nil
        }
        let title = episode["trackName"] as? String ?? episode["collectionName"] as? String
        if let feedURL = (episode["feedUrl"] as? String).flatMap(URL.init(string:)) ?? appleFeedURL(in: results),
           let result = try resolveRSSFeed(feedURL, request: request, expectedTitle: title, expectedURL: url.absoluteString),
           result.status == .playable {
            return result
        }
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
        return nil
    }

    private func resolveAppleLookupAsync(
        showId: String,
        episodeId: String,
        url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        let lookupURL = appleLookupURL(showId: showId)
        guard let data = try? await fetchAsync(lookupURL, timeout: requestTimeoutSeconds) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            return nil
        }
        guard let episode = appleEpisode(id: episodeId, in: results) else {
            if let feedURL = appleFeedURL(in: results) {
                return try await resolveRSSFeedAsync(
                    feedURL,
                    request: request,
                    expectedTitle: appleEpisodeTitleHint(in: url),
                    expectedURL: url.absoluteString,
                    requestTimeoutSeconds: requestTimeoutSeconds
                )
            }
            return nil
        }
        let title = episode["trackName"] as? String ?? episode["collectionName"] as? String
        if let feedURL = (episode["feedUrl"] as? String).flatMap(URL.init(string:)) ?? appleFeedURL(in: results),
           let result = try await resolveRSSFeedAsync(
                feedURL,
                request: request,
                expectedTitle: title,
                expectedURL: url.absoluteString,
                requestTimeoutSeconds: requestTimeoutSeconds
           ), result.status == .playable {
            return result
        }
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
        return nil
    }

    private func resolveApplePage(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        guard let data = try? fetch(url),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let pageTitle = htmlTitle(html)?.replacingOccurrences(of: " - Apple Podcasts", with: "") ?? title(from: url)
        if let feedURLString = jsonStringValue(named: "feedUrl", in: html),
           let feedURL = URL(string: feedURLString),
           let result = try resolveRSSFeed(feedURL, request: request, expectedTitle: pageTitle, expectedURL: url.absoluteString),
           result.status == .playable {
            return result
        }
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
        if let feedURLString = jsonStringValue(named: "feedUrl", in: html),
           let feedURL = URL(string: feedURLString),
           let result = try await resolveRSSFeedAsync(
                feedURL,
                request: request,
                expectedTitle: pageTitle,
                expectedURL: url.absoluteString,
                requestTimeoutSeconds: requestTimeoutSeconds
           ), result.status == .playable {
            return result
        }
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
        let chapterCollections = resolvedChapterCollections(for: selected)
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: url.absoluteString, provider: "rss", title: selected.feedTitle, role: "canonical_feed"),
            title: selected.title ?? expectedTitle ?? title(from: url),
            showTitle: selected.feedTitle,
            durationMs: selected.durationMs,
            publishedAt: selected.publishedAt,
            audioURL: audioURL,
            transcriptLinks: selected.transcriptLinks,
            chapterLinks: selected.chapterLinks,
            publisherChapterCollections: chapterCollections,
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
        let chapterCollections = await resolvedChapterCollections(
            for: selected,
            requestTimeoutSeconds: requestTimeoutSeconds
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: url.absoluteString, provider: "rss", title: selected.feedTitle, role: "canonical_feed"),
            title: selected.title ?? expectedTitle ?? title(from: url),
            showTitle: selected.feedTitle,
            durationMs: selected.durationMs,
            publishedAt: selected.publishedAt,
            audioURL: audioURL,
            transcriptLinks: selected.transcriptLinks,
            chapterLinks: selected.chapterLinks,
            publisherChapterCollections: chapterCollections,
            confidence: selected.isExactMatch ? 0.96 : 0.82
        )
        return playable(request: request, provider: "rss", candidate: candidate)
    }

    private func resolvedChapterCollections(for item: RSSFeedItem) -> [PublisherChapterCollection] {
        var collections: [PublisherChapterCollection] = []
        if let link = item.chapterLinks.first(where: isSupportedChapterLink),
           let url = URL(string: link.url),
           let data = try? fetch(url),
           let collection = Podcasting2ChapterJSONParser.parse(data) {
            collections.append(collection)
        }
        collections.append(contentsOf: item.publisherChapterCollections)
        return collections
    }

    private func resolvedChapterCollections(
        for item: RSSFeedItem,
        requestTimeoutSeconds: TimeInterval
    ) async -> [PublisherChapterCollection] {
        var collections: [PublisherChapterCollection] = []
        if let link = item.chapterLinks.first(where: isSupportedChapterLink),
           let url = URL(string: link.url),
           let data = try? await fetchAsync(url, timeout: requestTimeoutSeconds),
           let collection = Podcasting2ChapterJSONParser.parse(data) {
            collections.append(collection)
        }
        collections.append(contentsOf: item.publisherChapterCollections)
        return collections
    }

    private func resolveEpisodePage(_ url: URL, request: LinkResolutionRequest) throws -> LinkResolutionResult? {
        guard let data = try? fetch(url),
              let html = String(data: data, encoding: .utf8),
              let metadata = episodePageMetadata(in: html, pageURL: url) else {
            return nil
        }
        let collections = resolvedChapterCollections(for: RSSFeedItem(chapterLinks: metadata.chapterLinks))
        return playable(
            request: request,
            provider: "episode_page",
            candidate: episodePageCandidate(metadata: metadata, pageURL: url, collections: collections)
        )
    }

    private func resolveEpisodePageAsync(
        _ url: URL,
        request: LinkResolutionRequest,
        requestTimeoutSeconds: TimeInterval
    ) async throws -> LinkResolutionResult? {
        guard let data = try? await fetchAsync(url, timeout: requestTimeoutSeconds),
              let html = String(data: data, encoding: .utf8),
              let metadata = episodePageMetadata(in: html, pageURL: url) else {
            return nil
        }
        let collections = await resolvedChapterCollections(
            for: RSSFeedItem(chapterLinks: metadata.chapterLinks),
            requestTimeoutSeconds: requestTimeoutSeconds
        )
        return playable(
            request: request,
            provider: "episode_page",
            candidate: episodePageCandidate(metadata: metadata, pageURL: url, collections: collections)
        )
    }

    private func episodePageCandidate(
        metadata: EpisodePageMetadata,
        pageURL: URL,
        collections: [PublisherChapterCollection]
    ) -> LinkResolutionCandidate {
        LinkResolutionCandidate(
            sourceLink: SourceLink(
                url: pageURL.absoluteString,
                provider: "episode_page",
                title: metadata.title,
                role: "episode_page"
            ),
            title: metadata.title,
            showTitle: metadata.showTitle,
            durationMs: metadata.durationMs,
            publishedAt: metadata.publishedAt,
            audioURL: metadata.audioURL,
            transcriptLinks: metadata.transcriptLinks,
            chapterLinks: metadata.chapterLinks,
            publisherChapterCollections: collections,
            confidence: 0.9
        )
    }

    private func episodePageMetadata(in html: String, pageURL: URL) -> EpisodePageMetadata? {
        guard let encoded = episodeMetadataAttribute(in: html),
              encoded.count <= 32_000,
              let data = encoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAudioURL = (object["src"] ?? object["audio"] ?? object["contentUrl"]) as? String,
              let audioURL = URL(string: rawAudioURL, relativeTo: pageURL)?.absoluteURL,
              isHTTPURL(audioURL) else {
            return nil
        }
        let title = ((object["title"] as? String) ?? htmlTitle(html) ?? self.title(from: pageURL))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs: Int?
        if let duration = object["duration"] as? NSNumber {
            durationMs = max(0, Int((duration.doubleValue * 1_000).rounded()))
        } else if let duration = object["duration"] as? String, let seconds = Double(duration) {
            durationMs = max(0, Int((seconds * 1_000).rounded()))
        } else {
            durationMs = nil
        }

        var transcriptLinks: [SourceTranscriptLink] = []
        if let rawTranscriptURL = object["transcript"] as? String,
           let transcriptURL = URL(string: rawTranscriptURL, relativeTo: pageURL)?.absoluteURL,
           isHTTPURL(transcriptURL) {
            transcriptLinks.append(SourceTranscriptLink(
                url: transcriptURL.absoluteString,
                type: transcriptType(for: transcriptURL)
            ))
        }

        var chapterLinks: [SourceChapterLink] = []
        if let rawChapterURL = object["chapters"] as? String,
           let chapterURL = URL(string: rawChapterURL, relativeTo: pageURL)?.absoluteURL,
           isHTTPURL(chapterURL) {
            chapterLinks.append(SourceChapterLink(
                url: chapterURL.absoluteString,
                type: "application/json+chapters"
            ))
        }

        return EpisodePageMetadata(
            title: title.isEmpty ? self.title(from: pageURL) : title,
            showTitle: (object["showTitle"] ?? object["podcastName"]) as? String,
            durationMs: durationMs,
            publishedAt: object["publishedAt"] as? String,
            audioURL: audioURL.absoluteString,
            transcriptLinks: transcriptLinks,
            chapterLinks: chapterLinks
        )
    }

    private func episodeMetadataAttribute(in html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let patterns = [
            #"\bdata-(?:play|resume)-metadata-value\s*=\s*\"([^\"]+)\""#,
            #"\bdata-(?:play|resume)-metadata-value\s*=\s*'([^']+)'"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            return decodeHTMLEntities(String(html[valueRange]))
        }
        return nil
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func transcriptType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "vtt": return "text/vtt"
        case "srt": return "application/srt"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        default: return "text/plain"
        }
    }

    private func isSupportedChapterLink(_ link: SourceChapterLink) -> Bool {
        guard let url = URL(string: link.url), url.scheme?.lowercased() == "https" else { return false }
        let type = link.type.lowercased()
        return type == "application/json+chapters" || type == "application/json"
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
        if let expectedTitle, !expectedTitle.isEmpty {
            return nil
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

    private func review(
        request: LinkResolutionRequest,
        provider: String?,
        title: String,
        reason: String,
        candidates: [LinkResolutionCandidate]
    ) -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .needsReview,
            originalLink: SourceLink(url: request.inputURL, provider: provider, title: title, role: "discovery"),
            selectedCandidate: nil,
            candidates: candidates,
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
        return scheme == "https"
    }

    private func looksLikeRSSURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("rss") || lower.contains("feed") || lower.hasSuffix(".xml")
    }

    private func isApplePodcastsURL(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().contains("podcasts.apple.com")
    }

    private func isSpotifyURL(_ url: URL) -> Bool {
        isSpotifyHostURL(url) && url.path.lowercased().contains("/episode/")
    }

    private func isSpotifyHostURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "spotify.com" || host.hasSuffix(".spotify.com")
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func appleShowId(in url: URL) -> String? {
        url.pathComponents.lazy.compactMap { component -> String? in
            guard component.hasPrefix("id") else { return nil }
            let identifier = String(component.dropFirst(2))
            guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else { return nil }
            return identifier
        }.first
    }

    private func appleEpisodeTitleHint(in url: URL) -> String? {
        let components = url.pathComponents
        guard let showIdIndex = components.firstIndex(where: { component in
            guard component.hasPrefix("id") else { return false }
            let identifier = component.dropFirst(2)
            return !identifier.isEmpty && identifier.allSatisfy(\.isNumber)
        }), showIdIndex > components.startIndex else {
            return nil
        }
        let slug = components[components.index(before: showIdIndex)]
        guard slug != "/", !slug.isEmpty else { return nil }
        return slug.replacingOccurrences(of: "-", with: " ")
    }

    private func appleLookupURL(showId: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: showId),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: "200")
        ]
        return components.url!
    }

    private func appleEpisode(id: String, in results: [[String: Any]]) -> [String: Any]? {
        results.first { result in
            let isEpisode = (result["wrapperType"] as? String) == "podcastEpisode"
                || (result["kind"] as? String) == "podcast-episode"
            guard isEpisode else { return false }
            if let trackId = result["trackId"] as? NSNumber {
                return trackId.stringValue == id
            }
            if let trackId = result["trackId"] as? String {
                return trackId == id
            }
            return false
        }
    }

    private func appleFeedURL(in results: [[String: Any]]) -> URL? {
        results.lazy.compactMap { result in
            guard let value = result["feedUrl"] as? String else { return nil }
            return URL(string: value)
        }.first
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
    var chapterLinks: [SourceChapterLink] = []
    var publisherChapterCollections: [PublisherChapterCollection] = []
    var podloveChapters: [PublisherChapter] = []
    var description: String?
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
    private var isInPodloveChapters = false

    func parse(data: Data) -> [RSSFeedItem] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        _ = parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = localName(elementName)
        let namespace = namespaceURI?.lowercased()
        currentElement = element
        currentText = ""
        if element == "item" || element == "entry" {
            isInItem = true
            currentItem = RSSFeedItem(feedTitle: feedTitle)
        } else if isInItem, element == "enclosure" {
            currentItem?.enclosureURL = attributeDict["url"]
        } else if isInItem, element == "link", let href = attributeDict["href"], currentItem?.link == nil {
            currentItem?.link = href
        } else if isInItem,
                  element == "transcript",
                  isPodcasting20Namespace(namespace) {
            appendTranscriptLink(attributes: attributeDict)
        } else if isInItem,
                  element == "chapters",
                  isPodcasting20Namespace(namespace) {
            appendChapterLink(attributes: attributeDict)
        } else if isInItem,
                  element == "chapters",
                  namespace == "http://podlove.org/simple-chapters" {
            isInPodloveChapters = true
        } else if isInItem,
                  isInPodloveChapters,
                  element == "chapter",
                  namespace == "http://podlove.org/simple-chapters" {
            appendPodloveChapter(attributes: attributeDict)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += string
        }
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
            case "description", "encoded", "summary":
                if currentItem?.description?.isEmpty != false, !text.isEmpty {
                    currentItem?.description = text
                }
            case "chapters":
                if namespaceURI?.lowercased() == "http://podlove.org/simple-chapters" {
                    isInPodloveChapters = false
                }
            case "item", "entry":
                if var item = currentItem {
                    item.feedTitle = item.feedTitle ?? feedTitle
                    if !item.podloveChapters.isEmpty {
                        item.publisherChapterCollections.append(PublisherChapterCollection(
                            source: .podloveSimpleChapters,
                            chapters: item.podloveChapters
                        ))
                    }
                    if let description = item.description,
                       let descriptionChapters = TimestampedDescriptionChapterParser.parse(description) {
                        item.publisherChapterCollections.append(descriptionChapters)
                    }
                    items.append(item)
                }
                currentItem = nil
                isInItem = false
                isInPodloveChapters = false
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

    private func appendChapterLink(attributes: [String: String]) {
        let normalized = normalizedAttributes(attributes)
        guard let url = normalized["url"], !url.isEmpty,
              let type = normalized["type"], !type.isEmpty else { return }
        currentItem?.chapterLinks.append(SourceChapterLink(url: url, type: type))
    }

    private func appendPodloveChapter(attributes: [String: String]) {
        let normalized = normalizedAttributes(attributes)
        guard let rawStart = normalized["start"],
              let startMs = PodcastChapterTimeParser.milliseconds(rawStart),
              let rawTitle = normalized["title"] else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        currentItem?.podloveChapters.append(PublisherChapter(
            title: String(title.prefix(240)),
            startMs: startMs
        ))
    }

    private func normalizedAttributes(_ attributes: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: attributes.map { key, value in
            (key.lowercased(), value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func isPodcasting20Namespace(_ namespace: String?) -> Bool {
        guard let namespace else { return false }
        return namespace.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://podcastindex.org/namespace/1.0"
            || namespace == "https://github.com/podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
    }

    private func localName(_ elementName: String) -> String {
        (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
    }
}
