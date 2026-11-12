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

    /// One "Report" entry for the item's ⋯ menu: a link the item's friend Margins came from.
    public struct Entry: Equatable, Identifiable, Sendable {
        /// The link's public id; one entry per link.
        public let id: String
        /// The share page, where the report form is. Holds the id only, never the link's key.
        public let url: URL
        /// What the menu says: "Report this link" when the item has one link, else "Report <name>'s link".
        public let title: String
    }

    /// The links to offer in the item's ⋯ menu (#2239): one entry per distinct link the item's live friend layers
    /// were opened from. A layer from a file, a deleted layer and a damaged saved id offer nothing, so a listener is
    /// never sent anywhere but the share page. A friend who sent two links is listed twice, told apart by number.
    public static func entries(for layers: [ImportedCommentaryLayer]) -> [Entry] {
        var seen = Set<String>()
        var found: [(id: String, url: URL, name: String?)] = []
        for layer in layers where layer.deletedAt == nil {
            guard let linkId = layer.shareLinkId.flatMap(validLinkId), let url = pageURL(forLinkId: linkId) else { continue }
            let name = SharedPacketArrival.senderName(layer.displayLabel)
            if seen.insert(linkId).inserted {
                found.append((linkId, url, name))
            } else if let at = found.firstIndex(where: { $0.id == linkId }), found[at].name == nil {
                found[at].name = name // a later layer of the same link may be the one that names the sender
            }
        }
        guard found.count > 1 else {
            return found.map { Entry(id: $0.id, url: $0.url, title: "Report this link") }
        }
        var uses: [String: Int] = [:]
        let named = found.map { $0.name.map { "Report \($0)\u{2019}s link" } ?? "Report a link" }
        let totals = named.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return zip(found, named).map { link, title in
            var title = title
            if totals[title, default: 0] > 1 {
                uses[title, default: 0] += 1
                title += " (\(uses[title, default: 0]))"
            }
            return Entry(id: link.id, url: link.url, title: title)
        }
    }
}
