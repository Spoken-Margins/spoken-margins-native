import Foundation

/// The web page an item came from, for the Item screen's "Open Original Source" button (#1167).
///
/// Only an item added by link (an article, or an episode from a feed) keeps its page address in
/// `externalReference`, with `externalReferenceType` "url". Every other route stores a file path or a
/// label there. The address also has to pass ``ShareableLinkPolicy``: a link that may carry a
/// private-feed secret is never offered, because the button hands it to the browser and the browser
/// history.
public enum OriginalSourceLink {
    /// The address to open, or nil when the item has no public web page.
    public static func url(externalReference: String?, externalReferenceType: String?) -> URL? {
        guard externalReferenceType == "url", let externalReference else { return nil }
        let trimmed = externalReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = ShareableLinkPolicy.shareableLink(trimmed) else { return nil }
        return URL(string: address)
    }
}
