import Foundation
import SessionKit

extension LinkArticleFallback {
    /// The app's shared-link resolution (#223): the injected resolver when there is one (UI tests), otherwise the
    /// public podcast resolver, then the article fallback. Lives here because SessionKit can't see the resolver.
    @MainActor
    public static func resolve(
        _ request: LinkResolutionRequest,
        url: URL,
        resolver: (any LinkResolutionClient)?,
        allowsArticle: Bool,
        using extractor: any ReadablePageExtracting,
        record: (String) -> Void
    ) async throws -> Resolution {
        try await resolve(url: url, allowsArticle: allowsArticle, using: extractor, record: record) {
            if let resolver { return try resolver.resolve(request) }
            return try await PublicPodcastLinkResolver().resolveAsync(request)
        }
    }
}
