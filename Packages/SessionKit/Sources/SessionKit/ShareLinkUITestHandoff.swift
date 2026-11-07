import Foundation

#if DEBUG
/// A share link handed to a UI-test launch through the app's own scheme (#1842):
/// `spokenmargins://ui-test-share-link?url=<the whole link, percent-encoded>`.
///
/// GitHub's hosted simulators never route a universal link to the app: `J10OfflineJourneyUITests` skipped its share
/// link step on every hosted run from 2026-11-05 to 2026-11-07, so the offline check never saw a link fail. The app's
/// registered scheme always reaches `onOpenURL`, and from there the inner link takes the same path a tapped one does.
/// Debug only, and the app asks only for a UI-test launch (`UITestingHooks`). Release builds compile none of it.
public enum ShareLinkUITestHandoff {
    public static let scheme = "spokenmargins"
    public static let host = "ui-test-share-link"

    /// The share link inside `url`, or nil when `url` isn't a hand-off, or what it carries isn't on a share host.
    ///
    /// The `#key` must travel encoded inside the query. A hand-off with a fragment of its own is refused: its key
    /// would sit outside the link, and a keyless link fails as damaged before it ever asks the server.
    public static func shareLink(in url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let values = components.queryItems?.filter({ $0.name == "url" }), values.count == 1,
              let text = values[0].value, let link = URL(string: text),
              ShareLinkURL.isOnShareHost(link) else { return nil }
        return link
    }

    /// The hand-off that carries `link`. `J10OfflineJourneyUITests` builds the same string by hand, because the UI
    /// test target doesn't link SessionKit.
    public static func url(carrying link: URL) -> URL {
        let encoded = link.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "\(scheme)://\(host)?url=\(encoded)")!
    }
}
#endif
