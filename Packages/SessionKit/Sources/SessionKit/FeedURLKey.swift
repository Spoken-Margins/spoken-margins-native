import Foundation

/// The key two feed links share when they name the same feed (#4046). `https`, a lower-cased host, no fragment and no
/// trailing slash. An `http` feed in a file and its `https` subscription are the same feed, so the scheme is folded.
/// The path keeps its case, because paths are case-sensitive (Simplecast ids are mixed case).
///
/// OPML import, the source catalog and follow lists all match feeds by this key, so a list member written from one
/// path is found by the others.
public enum FeedURLKey {
    /// nil when `raw` has no host (not a feed link at all).
    public static func make(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
