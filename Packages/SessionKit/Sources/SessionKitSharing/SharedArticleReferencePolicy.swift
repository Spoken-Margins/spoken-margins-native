import Foundation
import SessionKit

/// When a packet's item is a web article the recipient doesn't have, the app can fetch it from the packet's
/// link (#916). Only an article qualifies: a podcast has its own acquisition, and a PDF or EPUB link isn't a page.
public enum SharedArticleReferencePolicy {
    /// The HTTPS page to read, or nil when the item isn't an article with a usable link.
    public static func articleURL(for item: SharedItemIdentity) -> URL? {
        guard item.itemType == .text,
              let normalized = SharedItemIdentityBuilder.normalizedSharingURL(item.canonicalURL),
              let url = URL(string: normalized),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Whether the page the reader landed on is the packet's article. A redirect to a consent wall, a sign-in
    /// page or another site returns text with no error, and Margins attached to it would never play (#916).
    /// The address the reader ended on has to be the packet's, or the text has to be the packet's text.
    public static func fetchedPageIsTheSharedArticle(
        _ item: SharedItemIdentity,
        fetchedURL: String,
        fetchedText: String
    ) -> Bool {
        if let expected = SharedItemIdentityBuilder.normalizedSharingURL(item.canonicalURL),
           SharedItemIdentityBuilder.normalizedSharingURL(fetchedURL) == expected {
            return true
        }
        guard let expectedHash = item.normalizedContentSHA256 else { return false }
        return PortableArticleAnchorResolver.normalizedContentSHA256(fetchedText) == expectedHash
    }
}
