import Foundation

/// Decides each navigation while the app's readable-page extractor reads one article: which ones load, which are
/// skipped, and which end the read. The app maps WebKit's navigation actions onto `decide`, so the rule is
/// host-testable.
///
/// Only the top-level page is the article. A navigation inside one of its frames (an embedded tweet or video, an
/// ad, an `about:blank` frame) or into a new window is skipped on its own. Before #144 any of them ended the read
/// as "Article URLs must use HTTPS.", and https frames used up the page's redirects.
public struct ReadablePageNavigationRules: Sendable {
    public static let maximumRedirects = 5

    public enum Refusal: Equatable, Sendable {
        /// The page itself went to an `http` address, or to one with no usable scheme or host (a downgrade).
        case pageLeftHTTPS
        /// The page itself was sent to another app's address (`x-safari-https://`, `twitter://`, `itms-apps://`):
        /// the site wants its own app or Safari, not this reader. The address isn't insecure, so it isn't
        /// called that (#4776).
        case handedToAnotherApp
        case tooManyRedirects
    }

    public enum Decision: Equatable, Sendable {
        case load
        /// Cancel this navigation only; the read carries on.
        case skipFrame
        /// Stop reading: the extraction fails.
        case refuse(Refusal)
    }

    /// Schemes that are a web address or a page's own local content. Any other scheme in the page's own
    /// navigation is a hand-off to an app. `http` stays a downgrade, and `about:`, `blob:`, `data:`,
    /// `javascript:`, `file:`, `ftp:`, `ws:` and `wss:` keep their refusal as before.
    private static let webOrLocalSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript", "file", "ftp", "ws", "wss"]

    /// Every host the read has contacted, the requested page's first.
    public private(set) var contactedHosts: [String]
    private var currentURL: URL
    private var redirectCount = 0

    public init(requestedURL: URL) {
        currentURL = requestedURL
        contactedHosts = requestedURL.host.map { [$0.lowercased()] } ?? []
    }

    /// - Parameters:
    ///   - targetIsMainFrame: whether the navigation's target is the top-level page; nil when it opens a new window.
    ///   - isRedirect: WebKit reports the navigation as type `.other` (a redirect or a script-driven load).
    public mutating func decide(url: URL?, targetIsMainFrame: Bool?, isRedirect: Bool) -> Decision {
        guard targetIsMainFrame == true else { return .skipFrame }
        guard let url else { return .refuse(.pageLeftHTTPS) }
        let scheme = url.scheme?.lowercased()
        if let scheme, !Self.webOrLocalSchemes.contains(scheme) {
            return .refuse(.handedToAnotherApp)
        }
        guard scheme == "https", let host = url.host?.lowercased() else {
            return .refuse(.pageLeftHTTPS)
        }
        if !contactedHosts.contains(host) { contactedHosts.append(host) }
        if isRedirect, url != currentURL {
            redirectCount += 1
            currentURL = url
            if redirectCount > Self.maximumRedirects { return .refuse(.tooManyRedirects) }
        }
        return .load
    }
}
