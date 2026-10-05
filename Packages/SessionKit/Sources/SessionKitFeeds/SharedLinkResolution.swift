import Foundation
import SessionKit

extension LinkArticleFallback {
    /// The app's shared-link resolution (#223): the injected resolver when there is one (UI tests), otherwise the
    /// public podcast resolver, then the article fallback. Lives here because SessionKit can't see the resolver.
    /// A public resolver keeps the pages it fetches in `pages`, so a shared post's voiceover lookup can read the
    /// post page again without a second request (#810).
    @MainActor
    public static func resolve(
        _ request: LinkResolutionRequest,
        url: URL,
        resolver: (any LinkResolutionClient)?,
        remembering pages: FetchedPageMemo,
        allowsArticle: Bool,
        using extractor: any ReadablePageExtracting,
        record: (String) -> Void
    ) async throws -> Resolution {
        try await resolve(url: url, allowsArticle: allowsArticle, using: extractor, record: record) {
            if let resolver {
                return try ((resolver as? PublicPodcastLinkResolver)?.remembering(pages) ?? resolver).resolve(request)
            }
            return try await PublicPodcastLinkResolver().remembering(pages).resolveAsync(request)
        }
    }
}
