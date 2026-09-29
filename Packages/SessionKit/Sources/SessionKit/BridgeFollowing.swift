import Foundation

// Following a site that publishes no feed, through the bridge manifest (#315 part 2).
// Pure logic, no storage or network: the app hands in what it holds (its follows,
// the BridgeSnapshot from BridgeManifestStore) and gets back what to show.
//
// Privacy rule (research/B4/DESIGN.md §5): at follow time the app pins the host of
// the link the listener actually shared, and only ever fetches items on that host.
// If a later manifest stops listing that host for the source, the follow stops
// updating until the listener confirms, so a bad manifest can't point phones at a
// host they never chose.

/// One bridged site the listener follows. Everything the phone needs to keep
/// following it offline; the server never sees this.
public struct BridgeFollow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// `BridgeSource.id` in the manifest.
    public var sourceId: String
    /// The host of the link the listener shared when they followed. Items on any
    /// other host are never fetched.
    public var followedHost: String
    public var title: String
    public var homepage: String
    public var createdAt: Date
    public var muted: Bool

    public init(id: String, sourceId: String, followedHost: String, title: String, homepage: String, createdAt: Date, muted: Bool = false) {
        self.id = id
        self.sourceId = sourceId
        self.followedHost = followedHost.lowercased()
        self.title = title
        self.homepage = homepage
        self.createdAt = createdAt
        self.muted = muted
    }
}

/// What the app can offer when a shared link has no feed but the bridge covers its site.
public struct BridgeFollowCandidate: Equatable, Sendable {
    public var source: BridgeSource
    public var followedHost: String

    /// A new follow, pinned to the host the listener shared.
    public func follow(id: String, at date: Date) -> BridgeFollow {
        BridgeFollow(id: id, sourceId: source.id, followedHost: followedHost, title: source.title, homepage: source.homepage, createdAt: date)
    }
}

/// An article link ready for Following. The phone fetches and extracts the article
/// itself with `recipe`; the manifest never carries its text.
public struct BridgeFollowItem: Equatable, Sendable {
    public var followId: String
    public var url: URL
    public var title: String
    public var publishedAt: Date?
    public var firstSeenAt: Date?
    public var recipe: BridgeRecipe
}

/// Why a followed bridged site shows "Not updating". Every case keeps the follow
/// and what the listener already has; none of them deletes anything.
public enum BridgeFollowPause: Equatable, Sendable {
    /// The bridge is off: kill switch, stale or malformed config, no config yet, or
    /// this build switched off.
    case bridgeOff(ServerFeatureOffReason)
    /// The bridge is on but no manifest has verified yet (first launch, outage).
    case noManifest
    /// The manifest no longer lists this site (removed, or dropped by sanitizing).
    case sourceUnavailable
    /// The owner paused or retired the site on the server.
    case sourcePaused
    /// The manifest no longer lists the host the listener followed. Needs the
    /// listener to confirm before anything is fetched from the new host.
    case hostChanged(newHosts: [String])
    /// The listener muted it.
    case muted
}

public enum BridgeFollowStatus: Equatable, Sendable {
    case updating
    case notUpdating(BridgeFollowPause)

    public var isUpdating: Bool { self == .updating }
}

public struct BridgeFollowUpdate: Equatable, Sendable {
    public var follow: BridgeFollow
    public var status: BridgeFollowStatus
    /// Newest first. Empty unless `status` is `.updating`.
    public var items: [BridgeFollowItem]
}

public enum BridgeFollowing {
    /// Keep the newest this many items per site, as feeds do.
    public static let maximumItemsPerSource = 25

    /// Whether a shared link can be followed through the bridge. Decided on the phone
    /// from the manifest it already has, so asking tells the server nothing. Nil when
    /// the bridge is off, the link isn't https, or no active source matches it.
    public static func candidate(for link: URL, snapshot: BridgeSnapshot) -> BridgeFollowCandidate? {
        guard snapshot.isUpdating, let manifest = snapshot.manifest,
              let source = manifest.source(matching: link), source.status == .active,
              let host = link.host?.lowercased() else { return nil }
        return BridgeFollowCandidate(source: source, followedHost: host)
    }

    /// What each follow should show now. Items are only ever on the pinned host.
    public static func updates(for follows: [BridgeFollow], snapshot: BridgeSnapshot) -> [BridgeFollowUpdate] {
        follows.map { update(for: $0, snapshot: snapshot) }
    }

    public static func update(for follow: BridgeFollow, snapshot: BridgeSnapshot) -> BridgeFollowUpdate {
        func paused(_ reason: BridgeFollowPause) -> BridgeFollowUpdate {
            BridgeFollowUpdate(follow: follow, status: .notUpdating(reason), items: [])
        }
        if follow.muted { return paused(.muted) }
        if case let .off(reason) = snapshot.state { return paused(.bridgeOff(reason)) }
        guard let manifest = snapshot.manifest else { return paused(.noManifest) }
        guard let source = manifest.source(id: follow.sourceId) else { return paused(.sourceUnavailable) }
        guard source.status == .active else { return paused(.sourcePaused) }
        guard source.match.hosts.contains(follow.followedHost) else {
            return paused(.hostChanged(newHosts: source.match.hosts))
        }
        var seen = Set<String>()
        let items = source.items.compactMap { item -> BridgeFollowItem? in
            guard let url = URL(string: item.url), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == follow.followedHost,
                  seen.insert(url.absoluteString).inserted else { return nil }
            return BridgeFollowItem(
                followId: follow.id,
                url: url,
                title: item.title,
                publishedAt: parseDate(item.publishedAt),
                firstSeenAt: parseDate(item.firstSeenAt),
                recipe: source.recipe
            )
        }
        .sorted { ($0.publishedAt ?? $0.firstSeenAt ?? .distantPast) > ($1.publishedAt ?? $1.firstSeenAt ?? .distantPast) }
        return BridgeFollowUpdate(follow: follow, status: .updating, items: Array(items.prefix(maximumItemsPerSource)))
    }

    /// The listener confirmed a host change: re-pin to the host they chose, which must
    /// be one the source now lists.
    public static func confirmHostChange(_ follow: BridgeFollow, to host: String, snapshot: BridgeSnapshot) -> BridgeFollow? {
        let host = host.lowercased()
        guard let source = snapshot.manifest?.source(id: follow.sourceId), source.match.hosts.contains(host) else { return nil }
        var updated = follow
        updated.followedHost = host
        return updated
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
