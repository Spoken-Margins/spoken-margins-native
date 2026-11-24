import Foundation

/// Where the sender's hidden check may go (#4454, #4783). A share link's own page (`https://spokenmargins.com/l/<id>#<key>`)
/// is the server's small preview page; in production it sends every browser on to the web listener at
/// `https://app.spokenmargins.com/l/<id>#<key>` (`data-web`, `research/B4/server/internal/links/preview.go`), which reads the
/// sealed packet from the link server and is the page that answers the check. So the check follows that one hop, to the
/// same link on the web listener's host, and loads only from the link's host, the web listener's and the link servers'.
/// Nothing here touches the network.
extension ShareLinkPlayCheck {
    /// The web listener's hosts (`research/B4/deploy/deploy-web.sh`, `edit-caddyfile.sh`). Exact hosts only.
    public static let webListenerHosts = ["app.spokenmargins.com", "app.spokenmargins.proximitytoprogress.com"]

    /// The hosts the hidden view may load anything from: the link's own, the web listener's (its page and files), and the
    /// link servers' (the sealed packet). Lower case, each once, the link's host first.
    public static func pageHosts(for link: URL) -> [String] {
        var hosts: [String] = []
        for host in [link.host?.lowercased()].compactMap({ $0 }) + webListenerHosts + ShareLinkURL.shareHosts where !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }

    /// Whether the hidden view may go to `url`: the link itself, or the same link on the web listener's host (same `/l/<id>`
    /// path, same key, no query), which is where the link's page sends it. Any other address (a report page, an outside
    /// link, a pop-up, another link) is never followed.
    public static func mayNavigate(to url: URL, from link: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let sameLink = url.path == link.path && url.query == link.query && url.fragment == link.fragment
            && url.user == nil && url.password == nil
        if host == link.host?.lowercased() { return sameLink && url.port == link.port }
        return webListenerHosts.contains(host) && url.port == nil && sameLink
    }

    /// Whether a message comes from a page the check loaded: the link's own host or the web listener's.
    public static func isCheckPageHost(_ host: String, link: URL) -> Bool {
        let host = host.lowercased()
        return host == link.host?.lowercased() || webListenerHosts.contains(host)
    }
}
