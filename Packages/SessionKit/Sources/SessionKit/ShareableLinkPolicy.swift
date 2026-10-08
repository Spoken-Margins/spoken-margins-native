import Foundation

/// Decides whether a link may leave the device in a shared packet, share link, Markdown export or log.
///
/// Paid podcast feeds (Patreon, Supercast, Substack and similar) are ordinary links with a
/// per-subscriber secret in the query, the path, the fragment or the userinfo. Anyone holding such a link can
/// listen as that subscriber. The policy drops the whole link rather than trimming it, because a
/// trimmed private link rarely still identifies the item and a missed secret is worse than a
/// missed match. The recipient then finds the item by title, show, GUID and duration.
///
/// The checks are heuristics. They favor privacy: a false alarm costs the recipient an automatic
/// match; a miss hands out access to someone's paid feed.
public enum ShareableLinkPolicy {
    /// Returns `value` unchanged when it is a web link that holds no access secret, otherwise nil.
    /// Packets additionally require https; their validator enforces that separately.
    public static func shareableLink(_ value: String?) -> String? {
        guard let value, isShareableLink(value) else { return nil }
        return value
    }

    /// Returns the GUID unchanged unless it is a link that fails ``shareableLink(_:)``.
    /// Plain GUIDs are the same for every subscriber, so they are safe to share and are the
    /// recipient's best way to find the episode in their own copy of a paid feed.
    public static func shareableEpisodeGUID(_ value: String?) -> String? {
        guard let value else { return nil }
        guard looksLikeLink(value) else { return value }
        return shareableLink(value)
    }

    private static let privateHostSuffixes = [
        "patreon.com", "patreonusercontent.com",
        "supercast.com", "supercast.tech",
        "supportingcast.fm",
        "memberful.com", "memberfulcontent.com"
    ]

    /// Public podcast feed hosts whose feed paths end in a hyphenless 32-hex identifier (#209).
    /// Only that exact shape is exempt there; every other check still applies. Scoped by host
    /// because the same shape elsewhere could be a private token.
    private static let publicHexIdentifierFeedHosts = ["rss.amperwave.net"]

    private static let privatePathMarkers: Set<String> = [
        "private", "premium", "paid", "subscriber", "subscribers",
        "member", "members", "patron", "patrons", "supporter", "supporters"
    ]

    private static let credentialQueryNameFragments = [
        "token", "auth", "key", "secret", "sig", "hash", "pass", "pwd",
        "session", "credential", "jwt", "expire", "policy", "hmac", "access"
    ]

    private static func isShareableLink(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), looksLikeLink(value),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        if privateHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return false
        }
        let allowsHexIdentifiers = publicHexIdentifierFeedHosts.contains(host)
        for segment in components.percentEncodedPath.split(separator: "/") {
            if pathSegmentHoldsCredential(String(segment), allowsHexIdentifiers: allowsHexIdentifiers) { return false }
        }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if credentialQueryNameFragments.contains(where: name.contains) { return false }
            if let itemValue = item.value, looksLikeSecret(itemValue) { return false }
        }
        if let fragment = components.percentEncodedFragment, fragmentHoldsCredential(fragment) { return false }
        return true
    }

    /// One path segment, read after percent-decoding so `%70remium` is `premium` (#1050).
    private static func pathSegmentHoldsCredential(_ segment: String, allowsHexIdentifiers: Bool) -> Bool {
        let decoded = fullyDecoded(segment)
        // An encoded slash (`%2F`) keeps several segments inside one; a marker behind it still counts.
        // The secret shape is judged on the whole segment, so an encoded URL inside a segment
        // (anchor.fm) is not mistaken for a long token.
        for part in decoded.split(separator: "/") where privatePathMarkers.contains(stem(of: part).lowercased()) {
            return true
        }
        let wholeStem = stem(of: decoded[...])
        if allowsHexIdentifiers, isHyphenlessUUID(wholeStem) { return false }
        return looksLikeSecret(wholeStem)
    }

    /// The `#fragment` never reaches a server, but the link is copied into packets, notes, OPML,
    /// Readwise and the community map, so a secret kept there travels with it (#1050). Only a
    /// credential-looking fragment is refused: an ordinary anchor such as `#section-2` is on every
    /// public article. A fragment is read the way it is usually used:
    /// - as a query string when it holds `=` (`#token=abc`), or after the `?` of a route (`#/list?auth=abc`),
    ///   with the query's name and length rules;
    /// - as a route when it holds `/` (`#/private/abc`, `#!/members/abc`), with the path's marker and length rules;
    /// - otherwise as a bare anchor, refused only when the whole anchor is a long opaque token.
    private static func fragmentHoldsCredential(_ percentEncodedFragment: String) -> Bool {
        let fragment = fullyDecoded(percentEncodedFragment)
        var route = Substring(fragment)
        var query = Substring()
        if fragment.hasPrefix("/") || fragment.hasPrefix("!/") {
            if let mark = fragment.firstIndex(of: "?") {
                route = fragment[..<mark]
                query = fragment[fragment.index(after: mark)...]
            }
        } else if fragment.contains("=") {
            route = ""
            query = Substring(fragment)
        }
        let segments = route.split(separator: "/")
        if route.contains("/"), segments.contains(where: { privatePathMarkers.contains(stem(of: $0).lowercased()) }) {
            return true
        }
        if segments.contains(where: { looksLikeSecret(stem(of: $0)) }) { return true }
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].lowercased()
            if credentialQueryNameFragments.contains(where: name.contains) { return true }
            if pair.count > 1, looksLikeSecret(String(pair[1])) { return true }
        }
        return false
    }

    /// The segment up to its first dot: `premium.rss` is the marker `premium`.
    private static func stem(of segment: Substring) -> String {
        segment.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(segment)
    }

    /// Percent-decodes `value` until it stops changing, at most three rounds. Some servers and
    /// proxies decode twice, so `%2570remium` can reach the origin as `premium`.
    private static func fullyDecoded(_ value: String) -> String {
        var current = value
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else { break }
            current = decoded
        }
        return current
    }

    /// A long opaque run of letters and digits, as used for tokens, signatures and API keys.
    /// UUIDs are excluded: public podcast hosts (Simplecast, Omny, Art19) put them in every link.
    private static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard trimmed.count >= 32, UUID(uuidString: trimmed) == nil else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return trimmed.contains(where: \.isLetter) && trimmed.contains(where: \.isNumber)
    }

    private static func isHyphenlessUUID(_ value: String) -> Bool {
        value.count == 32 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    private static func looksLikeLink(_ value: String) -> Bool {
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
