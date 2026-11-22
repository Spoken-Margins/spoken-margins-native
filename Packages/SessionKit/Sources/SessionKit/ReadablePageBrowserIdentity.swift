import Foundation

/// The browser identity the app's readable-page reader gives a site that answers its default one with a hand-off
/// to Safari instead of the page (#4776).
///
/// X answers any iPhone user agent, including a web view's, with `302 x-safari-https://redirect.x.com/<path>`.
/// That address isn't one a web view can load, so an X post link failed with "the page moved to an address that
/// isn't secure". The same request with a Mac Safari identity gets the post's page (200), whose server-drawn HTML
/// already carries the post's text. The reader blocks every script and subresource and keeps no cookies, so the
/// identity is the only thing that changes. Only hosts known to do this are listed; every other site gets the
/// web view's own identity.
public enum ReadablePageBrowserIdentity {
    /// Mac Safari's. X sent the post page to this and a Safari-to-app hand-off to the iPhone one (checked 2026-11-22).
    public static let macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Registrable domains whose iPhone-identity answer is a hand-off to Safari. A host matches when it is the
    /// domain or a subdomain of it, never when it merely ends with the same letters.
    private static let handOffDomains = ["x.com", "twitter.com"]

    /// The user agent to read `url` with, or nil to keep the web view's own.
    public static func userAgent(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let matches = handOffDomains.contains { host == $0 || host.hasSuffix("." + $0) }
        return matches ? macSafari : nil
    }
}
