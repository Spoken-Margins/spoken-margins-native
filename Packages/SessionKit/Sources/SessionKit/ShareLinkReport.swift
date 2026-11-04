import Foundation

/// Where a listener goes to report a share link they received (#2846, Apple agreement 10(v)).
///
/// The share page carries the "Report this link" form and its categories (#2239), so a report from the app and one
/// from the page go through the same handling. The app only needs to know which page to open. The address names the
/// link's public id and nothing else: never the key from the link, which stays on the phone, and never the
/// listener's Margins or anything else about them.
public enum ShareLinkReport {
    /// The page of the share link with `linkId`, or nil when `linkId` is not a link id (so a damaged value saved
    /// by mistake can't send the listener somewhere else).
    public static func pageURL(forLinkId linkId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = BridgeManifestPolicy.production.trustedHost
        components.path = "/l/\(linkId)"
        // `ShareLinkURL` holds the one definition of a valid id (32 lowercase hex characters).
        guard let url = components.url, let link = ShareLinkURL(url: url), link.id == linkId else { return nil }
        return url
    }

    /// `linkId` itself when it is a link id, else nil: what a layer may keep as its link.
    public static func validLinkId(_ linkId: String) -> String? {
        pageURL(forLinkId: linkId) == nil ? nil : linkId
    }
}
