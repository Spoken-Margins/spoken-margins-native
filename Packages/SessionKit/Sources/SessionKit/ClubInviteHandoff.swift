import Foundation

/// A club invite handed to the app by the invitation page's "Open in Spoken Margins" button (#1799, slice 4):
/// `spokenmargins://club?link=<the https invite link, percent-encoded>`.
///
/// Only the browser has the key, which is in the link's `#` part, so the page copies the whole link into the query.
/// The button is always compiled in: unlike `ShareLinkUITestHandoff`, this is how an invite reaches a release build
/// from Safari. Nothing here reads the club's key into a log or a description: it hands the link to
/// `ClubInvite.parse`, which holds the rules (the product host, `/c/<id>`, an id that matches the key).
public enum ClubInviteHandoff {
    public static let scheme = "spokenmargins"
    public static let host = "club"

    /// What `url` carries. `.notAClubLink` means this is not a club hand-off at all, or its link is not on the share
    /// host or not a `/c/` link, so another handler may take it. `.incompleteOrDamaged` is a club link that cannot
    /// open. A hand-off with a fragment of its own, a path, a port, a user, any other query item, or the `link` named twice
    /// is refused as `.notAClubLink`: the key would sit outside the link, or two links would compete for the same tap,
    /// and the page builds only the plain shape.
    public static func parse(_ url: URL) -> ClubInvite.Parsed {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty, components.port == nil, components.user == nil, components.password == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "link",
              let text = items[0].value, let link = URL(string: text) else { return .notAClubLink }
        return ClubInvite.parse(link)
    }

    /// The hand-off that carries `invite`, as the landing page builds it.
    public static func url(carrying invite: ClubInvite, host linkHost: String = ProductServer.productionHost) -> URL {
        let encoded = invite.url(host: linkHost).absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "\(scheme)://\(host)?link=\(encoded)")!
    }
}
