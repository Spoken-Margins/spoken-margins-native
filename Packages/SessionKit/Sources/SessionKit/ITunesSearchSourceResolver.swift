import Foundation

/// Fetches `url`, reading at most `maximumBytes` of body. Returns the HTTP status and body.
/// The app implements this with URLSession; tests pass recorded responses.
public typealias SourceHTTPFetch = @Sendable (_ url: URL, _ maximumBytes: Int) async throws -> (status: Int, body: Data)

/// Seam I1 resolver for podcast names (B1 M2): Apple's public iTunes Search API.
///
/// Apple's order is kept, except that shows whose title is the query come first, then
/// shows whose title and publisher contain every query word. A name never proves which
/// show is meant, so the best candidate is at most `likely`, and only when its title is
/// the query. Shows with no public feed (Apple or Spotify exclusives) are returned
/// unfollowable, with a reason, rather than dropped, so the listener learns why.
public struct ITunesSearchSourceResolver: SourceResolver {
    public let id = "itunes_search"
    public static let maximumResponseBytes = 512 * 1_024

    private let fetch: SourceHTTPFetch
    private let country: String
    private let limit: Int

    public init(country: String = "us", limit: Int = 15, fetch: @escaping SourceHTTPFetch) {
        self.country = country
        self.limit = limit
        self.fetch = fetch
    }

    public func canResolve(_ input: SourceResolutionInput) -> Bool {
        guard case .query(let query) = input else { return false }
        return !Self.words(query).isEmpty
    }

    public func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "term", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country),
        ]
        return components.url!
    }

    public func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate] {
        guard case .query(let query) = input, canResolve(input) else { return [] }
        let (status, body) = try await fetch(searchURL(for: query), Self.maximumResponseBytes)
        guard (200..<300).contains(status) else { throw ITunesSearchError.httpStatus(status) }
        return try Self.candidates(query: query, responseBody: body, resolverId: id)
    }

    /// Ranks a recorded or live response. Separate from networking so tests replay fixtures.
    public static func candidates(query: String, responseBody: Data, resolverId: String = "itunes_search") throws -> [SourceCandidate] {
        guard let response = try? JSONDecoder().decode(ITunesSearchResponse.self, from: responseBody) else {
            throw ITunesSearchError.invalidResponse
        }
        let queryWords = words(query)
        let normalizedQuery = queryWords.joined(separator: " ")
        let ranked = response.results.enumerated().compactMap { position, result -> (tier: Int, position: Int, result: ITunesSearchResult)? in
            guard let title = result.collectionName, !title.isEmpty else { return nil }
            let titleWords = words(title)
            let tier: Int
            if titleWords.joined(separator: " ") == normalizedQuery {
                tier = 0
            } else if Set(titleWords + words(result.artistName ?? "")).isSuperset(of: queryWords) {
                tier = 1
            } else {
                tier = 2
            }
            return (tier, position, result)
        }.sorted { ($0.tier, $0.position) < ($1.tier, $1.position) }

        return ranked.enumerated().map { rank, item in
            let result = item.result
            let feedURL = result.feedUrl.flatMap(httpsFeedURL)
            let confidence: SourceCandidateConfidence = (rank == 0 && item.tier == 0) ? .likely : .possible
            let reason: String
            switch (item.tier, feedURL) {
            case (_, nil): reason = "No public feed: this show is exclusive to another app"
            case (0, _): reason = "Title matches the search"
            case (1, _): reason = "Title and publisher contain every word searched"
            default: reason = "Apple's search suggested it"
            }
            let appleId = result.collectionId.map(String.init)
            return SourceCandidate(
                id: "\(resolverId):\(appleId ?? String(item.position))",
                kind: .podcastFeed,
                contentKind: .podcast,
                title: result.collectionName ?? "",
                author: result.artistName,
                artworkURL: (result.artworkUrl600 ?? result.artworkUrl100).flatMap { SourceCatalogValidator.isHTTPS($0) ? $0 : nil },
                websiteURL: nil,
                feed: feedURL.map { SourceCandidateFeed(url: $0) },
                confidence: confidence,
                score: 1 - Double(rank) / Double(max(ranked.count, 1)),
                reason: reason,
                resolverId: resolverId,
                externalIds: appleId.map { SourceExternalIds(applePodcastsId: $0) }
            )
        }
    }

    /// The follow path requires https (ATS), so http feeds are offered as https.
    /// If the host doesn't serve https, following fails visibly rather than silently downgrading.
    static func httpsFeedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              !(components.host ?? "").isEmpty else { return nil }
        components.scheme = "https"
        return components.string
    }

    static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "%", with: " percent ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "podcast", "show", "with"]
}

public enum ITunesSearchError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case invalidResponse
}

struct ITunesSearchResponse: Decodable {
    var results: [ITunesSearchResult]
}

struct ITunesSearchResult: Decodable {
    var collectionId: Int?
    var collectionName: String?
    var artistName: String?
    var feedUrl: String?
    var artworkUrl600: String?
    var artworkUrl100: String?
}
