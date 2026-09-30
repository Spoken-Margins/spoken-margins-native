import Foundation

/// Compares podcast enclosure URLs by the file they finally point at.
///
/// Feeds wrap the same audio file in analytics redirects (Podtrac, swap.fm, Chartable, Podsights and others) and
/// add tracking query strings, and the wrapping differs between a sender's copy and a recipient's lookup. Two
/// enclosures that unwrap to the same host and path are the same episode file.
public enum PodcastEnclosureIdentity {
    /// Redirect prefixes as `host/path-prefix` followed by the number of opaque path segments to drop after it.
    private static let redirectPrefixes: [(prefix: String, opaqueSegments: Int)] = [
        ("podtrac.com/pts/redirect.mp3", 0),
        ("dts.podtrac.com/redirect.mp3", 0),
        ("dts.podtrac.com/redirect.m4a", 0),
        ("www.podtrac.com/pts/redirect.mp3", 0),
        ("tracking.swap.fm/track", 1),
        ("chtbl.com/track", 1),
        ("pdst.fm/e", 0),
        ("pscrb.fm/rss/p", 0),
        ("verifi.podscribe.com/rss/p", 0),
        ("arttrk.com/p", 1),
        ("pfx.vpixl.com", 1),
        ("mgln.ai/e", 1),
        ("claritaspod.com/measure", 0),
        ("op3.dev/e", 0),
        ("prfx.byspotify.com/e", 0),
        ("prefix.up.audio/s", 0)
    ]

    public static func key(_ value: String?) -> String? {
        guard let value, let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var remainder = host + components.path
        var unwrapped = true
        while unwrapped {
            unwrapped = false
            for (prefix, opaqueSegments) in redirectPrefixes where remainder.lowercased().hasPrefix(prefix + "/") {
                var segments = remainder.dropFirst(prefix.count + 1).split(separator: "/", omittingEmptySubsequences: true)
                guard segments.count > opaqueSegments + 1 else { break }
                segments.removeFirst(opaqueSegments)
                var next = segments.joined(separator: "/")
                for scheme in ["https:/", "http:/", "https:", "http:"] where next.lowercased().hasPrefix(scheme) {
                    next = String(next.dropFirst(scheme.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                remainder = next
                unwrapped = true
                break
            }
        }
        guard let slash = remainder.firstIndex(of: "/") else { return remainder.lowercased() }
        let finalHost = remainder[..<slash].lowercased()
        var path = String(remainder[slash...])
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        return finalHost + path
    }

    public static func sameFile(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = key(lhs), let right = key(rhs) else { return false }
        return left == right
    }
}
