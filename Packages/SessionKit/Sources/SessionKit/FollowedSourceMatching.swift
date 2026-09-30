import Foundation

/// Whether a source is already followed, and which discovered feeds are new (B2). Moved out of
/// Gate1AppModel so the Follow button, the suggestion card and the tap share one host-tested rule.
public enum FollowedSourceMatching {
    public static func isSourceAlreadyFollowed(
        sourceURL: String?,
        sourceTitle: String?,
        subscriptions: [FeedSubscription]
    ) -> Bool {
        if let sourceURL = normalizedFollowSourceURL(sourceURL) {
            return subscriptions.contains {
                normalizedFollowSourceURL($0.source.canonicalURL) == sourceURL
            }
        }
        guard let sourceTitle = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceTitle.isEmpty else { return false }
        return subscriptions.contains {
            ($0.source.title ?? $0.source.host).caseInsensitiveCompare(sourceTitle) == .orderedSame
        }
    }

    public static func uniqueUnfollowedCandidates(
        _ candidates: [SourceCandidateEvidence], subscriptions: [FeedSubscription]
    ) -> [SourceCandidateEvidence] {
        var sourceIDs = Set<String>()
        var urls = Set<String>()
        return candidates.filter { candidate in
            let url = normalizedFollowSourceURL(candidate.source.canonicalURL) ?? candidate.source.canonicalURL
            guard !subscriptions.contains(where: {
                $0.source.id == candidate.source.id
                    || normalizedFollowSourceURL($0.source.canonicalURL) == url
            }) else { return false }
            let newID = sourceIDs.insert(candidate.source.id).inserted
            let newURL = urls.insert(url).inserted
            return newID && newURL
        }
    }

    static func normalizedFollowSourceURL(_ value: String?) -> String? {
        guard let value,
              var components = URLComponents(
                string: value.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !scheme.isEmpty,
              !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
