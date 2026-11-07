import Foundation

/// #3548: which sites a listener follows or links to is their reading list, and a bare host name has no shape the
/// export's scrubbers can tell from other words. So the app never writes a host into a diagnostics value: it
/// writes how many hosts a step contacted, or a provider id from our own fixed list. The export stays useful for
/// "did the network step run" and "which of our resolvers answered" without naming a publisher.
public enum DiagnosticsHostRedaction {
    /// Stands where a host used to be in a one-line diagnostic.
    public static let hostPlaceholder = "<site>"

    /// "none", "1 host" or "N hosts": the only thing a diagnostics value says about the hosts a step contacted.
    public static func hostCount(_ hosts: some Collection<String>) -> String {
        let distinct = Set(hosts.map { $0.lowercased() }.filter { !$0.isEmpty }).count
        switch distinct {
        case 0: return "none"
        case 1: return "1 host"
        default: return "\(distinct) hosts"
        }
    }

    /// The provider ids `PublicPodcastLinkResolver` and the package importer write. Add a new id here when a new
    /// resolver is added; an id that is not listed reads as `other_site`, which is safe and visible in a test.
    public static let resolverIds: Set<String> = [
        "spotify", "apple_podcasts", "direct_audio", "rss", "episode_page", "shared_package",
    ]

    /// A link provider is one of our resolver ids or, for a page we could only read the metadata of, the page's
    /// host (`url.host` is passed as the provider). Listed ids pass; anything else is `other_site`.
    public static func providerLabel(_ provider: String?) -> String {
        guard let provider, !provider.isEmpty else { return "unknown" }
        return resolverIds.contains(provider) ? provider : "other_site"
    }

    /// Replaces every host-shaped word (`name.example.com`, `www.site.co.uk`) and every `@handle` in a one-line
    /// diagnostic with `<site>`. Used on discovery traces that were written as "page on <host>: status 404".
    /// It over-redacts on purpose: `feed.xml` also becomes `<site>`, and a trace that says less is still safe.
    public static func redactingHosts(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let hosts = hostPattern.stringByReplacingMatches(in: text, range: range, withTemplate: hostPlaceholder)
        let handleRange = NSRange(hosts.startIndex..., in: hosts)
        return handlePattern.stringByReplacingMatches(in: hosts, range: handleRange, withTemplate: hostPlaceholder)
    }

    private static let hostPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_@])(?:(?:[\\p{L}\\p{N}_](?:[\\p{L}\\p{N}_-]*[\\p{L}\\p{N}_])?\\.)+\\p{L}{2,}|[0-9]{1,3}(?:\\.[0-9]{1,3}){3})(?::[0-9]+)?(?![\\p{L}\\p{N}_])")
    private static let handlePattern = try! NSRegularExpression(pattern: "@[A-Za-z0-9_.-]+")
}
