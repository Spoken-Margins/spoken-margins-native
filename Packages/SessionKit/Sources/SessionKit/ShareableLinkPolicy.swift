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
        // Each name and value is decoded here, not by `queryItems`, which leaves a whole item
        // undecoded when one escape in it is malformed (`?%74oken=abc%zz`, #945).
        for item in (components.percentEncodedQuery ?? "").split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = fullyDecoded(String(pair[0])).lowercased()
            if credentialQueryNameFragments.contains(where: name.contains) { return false }
            if pair.count > 1, looksLikeSecret(fullyDecoded(String(pair[1]))) { return false }
        }
        if let fragment = components.percentEncodedFragment, fragmentHoldsCredential(fragment) { return false }
        return true
    }

    /// One path segment, read after percent-decoding so `%70remium` is `premium` (#1050).
    private static func pathSegmentHoldsCredential(_ segment: String, allowsHexIdentifiers: Bool) -> Bool {
        let decoded = fullyDecoded(segment)
        // An encoded slash (`%2F`) keeps several segments inside one; a marker behind it still counts.
        let parts = decoded.split(separator: "/")
        for part in parts where privatePathMarkers.contains(stem(of: part).lowercased()) {
            return true
        }
        // An encoded URL inside a segment (anchor.fm) holds a long run of its own, which the secret
        // shape would mistake for a token, so it is judged whole. Any other segment is judged part by
        // part, as the path segments an encoded slash makes of it: that includes a token with a slash
        // before or after it (`TOKEN%2F`), which leaves one part, not several (#945).
        if !decoded.contains("://") {
            return parts.contains { part in
                let partStem = stem(of: part)
                if allowsHexIdentifiers, isHyphenlessUUID(partStem) { return false }
                return looksLikeSecret(partStem)
            }
        }
        let wholeStem = stem(of: decoded[...])
        if allowsHexIdentifiers, isHyphenlessUUID(wholeStem) { return false }
        return looksLikeSecret(wholeStem)
    }

    /// The `#fragment` never reaches a server, but the link is copied into packets, notes, OPML,
    /// Readwise and the community map, so a secret kept there travels with it (#1050). Only a
    /// credential-looking fragment is refused: an ordinary anchor such as `#section-2` is on every
    /// public article. A fragment is read every way it is usually used, and any one reading is enough:
    /// - as a route when it holds `/` (`#/private/abc`, `#!/members/abc`), with the path's marker rules;
    /// - as path segments or a bare anchor, refused when one is a long opaque token (the path's length rule);
    /// - as a query string: every `name=value` pair, and every item after a `?`, with the query's
    ///   name and length rules (`#token=abc`, `#/access_token=abc&x=1`, `#/list?auth=abc`).
    private static func fragmentHoldsCredential(_ percentEncodedFragment: String) -> Bool {
        var fragment = fullyDecoded(percentEncodedFragment)
        // A browser consumes everything from ":~:" on as a text-fragment directive that quotes the
        // page (`#:~:text=Q%26A%20on%20passwords`). It holds no credential, and its quoted words
        // must not be read as names.
        if let directive = fragment.range(of: ":~:") { fragment = String(fragment[..<directive.lowerBound]) }
        if fragment.hasPrefix("!") { fragment.removeFirst() }
        let halves = fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let head = halves[0]
        let tail = halves.count > 1 ? halves[1] : ""
        let segments = head.split(separator: "/")
        if head.contains("/"), segments.contains(where: { privatePathMarkers.contains(stem(of: $0).lowercased()) }) {
            return true
        }
        if segments.contains(where: { looksLikeSecret(stem(of: $0)) }) { return true }
        for item in head.split(separator: "&") where item.contains("=") && queryItemHoldsCredential(item) { return true }
        for item in tail.split(separator: "&") where queryItemHoldsCredential(item) { return true }
        return false
    }

    /// One `name=value` item, with the query's rules: a credential-like name, or a value that is a long opaque token.
    private static func queryItemHoldsCredential(_ item: Substring) -> Bool {
        let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = pair[0].lowercased()
        if credentialQueryNameFragments.contains(where: name.contains) { return true }
        return pair.count > 1 && looksLikeSecret(String(pair[1]))
    }

    /// The segment up to its first dot: `premium.rss` is the marker `premium`.
    private static func stem(of segment: Substring) -> String {
        segment.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(segment)
    }

    /// Percent-decodes `value` until it stops changing, at most three rounds. Some servers and
    /// proxies decode twice, so `%2570remium` can reach the origin as `premium`.
    ///
    /// Decoding is lenient, as a browser or a tolerant server is: an escape that is not two hex
    /// digits (`%zz`, a lone `%`) stays as written and the valid escapes around it still decode, so
    /// one bad escape cannot keep `%70remium.rss%zz` from being read as `premium.rss%zz` (#945).
    /// Bytes that are not valid UTF-8 after decoding become U+FFFD, which no check treats as a secret.
    private static func fullyDecoded(_ value: String) -> String {
        var current = value
        for _ in 0..<3 {
            let decoded = decodedOnce(current)
            guard decoded != current else { break }
            current = decoded
        }
        return current
    }

    private static func decodedOnce(_ value: String) -> String {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == UInt8(ascii: "%"), index + 2 < input.count,
               let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// A long opaque run of letters and digits, as used for tokens, signatures and API keys.
    /// UUIDs are excluded: public podcast hosts (Simplecast, Omny, Art19) put them in every link.
    ///
    /// A `%` that is left after decoding is a stray one (`%zz`, a trailing `%`) or a literal percent
    /// sign. It is dropped first, so a bad escape beside a token cannot keep the token from being seen (#945).
    private static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
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
