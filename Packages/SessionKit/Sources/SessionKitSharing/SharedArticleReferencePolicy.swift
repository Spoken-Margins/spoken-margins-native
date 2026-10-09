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
}
