import Foundation

/// Decides whether a link may leave the device in a shared packet, share link, Markdown export or log.
///
/// Paid podcast feeds (Patreon, Supercast, Substack and similar) are ordinary links with a
/// per-subscriber secret in the query, the path or the userinfo. Anyone holding such a link can
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
        let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        let allowsHexIdentifiers = publicHexIdentifierFeedHosts.contains(host)
        for segment in segments {
            let stem = segment.split(separator: ".", maxSplits: 1).first.map(String.init) ?? segment
            if privatePathMarkers.contains(stem.lowercased()) { return false }
            if allowsHexIdentifiers, isHyphenlessUUID(stem) { continue }
            if looksLikeSecret(stem) { return false }
        }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if credentialQueryNameFragments.contains(where: name.contains) { return false }
            if let itemValue = item.value, looksLikeSecret(itemValue) { return false }
        }
        return true
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
