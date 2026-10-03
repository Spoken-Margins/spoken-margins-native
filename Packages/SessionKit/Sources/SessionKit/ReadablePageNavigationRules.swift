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
        /// The page itself went to an address that isn't HTTPS.
        case pageLeftHTTPS
        case tooManyRedirects
    }

    public enum Decision: Equatable, Sendable {
        case load
        /// Cancel this navigation only; the read carries on.
        case skipFrame
        /// Stop reading: the extraction fails.
        case refuse(Refusal)
    }

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
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
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
