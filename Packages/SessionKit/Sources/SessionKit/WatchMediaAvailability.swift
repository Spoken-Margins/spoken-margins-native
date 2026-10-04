import Foundation

/// What a standalone Watch can play an item from (#789, slice of #75).
public enum WatchMediaKind: String, Codable, Equatable, Hashable, Sendable {
    /// A podcast episode's own audio, from its feed enclosure.
    case podcastEpisode
    /// Audio the phone rendered ahead of time for a text item. The Watch never renders speech.
    case preRenderedAudio
}

/// One exact piece of media for one revision of one item.
///
/// `sourceRevision` changes whenever the item's content changes (a re-import, a new edition, a
/// re-render), so media and positions for one revision are never used for another.
public struct WatchMediaIdentity: Codable, Equatable, Hashable, Sendable {
    public var itemId: String
    public var sourceRevision: String
    public var kind: WatchMediaKind
    /// The enclosure's GUID or URL for an episode; the prepared edition's id for rendered audio.
    public var mediaId: String

    public init(itemId: String, sourceRevision: String, kind: WatchMediaKind, mediaId: String) {
        self.itemId = itemId
        self.sourceRevision = sourceRevision
        self.kind = kind
        self.mediaId = mediaId
    }

    /// The same media, ignoring the revision: used to find what a new revision replaces.
    public func sameMedia(as other: WatchMediaIdentity) -> Bool {
        itemId == other.itemId && kind == other.kind && mediaId == other.mediaId
    }
}

/// An address the Watch can stream from. It never makes media offline-ready.
public struct WatchMediaRemote: Codable, Equatable, Sendable {
    public var url: URL
    /// Signed or temporary links stop working after this.
    public var expiresAt: Date?

    public init(url: URL, expiresAt: Date? = nil) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Media fully on the Watch: checked against its manifest and committed in one step.
public struct WatchMediaInstall: Codable, Equatable, Sendable {
    public var identity: WatchMediaIdentity
    public var fileName: String
    public var byteCount: Int
    public var sha256: String
    public var durationMs: Int
    public var installedAt: Date

    public init(identity: WatchMediaIdentity, fileName: String, byteCount: Int, sha256: String, durationMs: Int, installedAt: Date) {
        self.identity = identity
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMs = durationMs
        self.installedAt = installedAt
    }
}

/// How the Watch can play an item right now.
public enum WatchMediaPlayability: Equatable, Sendable {
    /// Installed and verified for the current revision; plays with no connection.
    case local(WatchMediaInstall)
    /// Online only. `durationMs` is the feed's or phone's stated length, not a measured file.
    case stream(WatchMediaRemote, durationMs: Int?)
    case unavailable(WatchMediaUnavailableReason)

    /// The duration to show. Only a verified install or a stated stream length gives one.
    public var durationMs: Int? {
        switch self {
        case .local(let install): install.durationMs
        case .stream(_, let durationMs): durationMs
        case .unavailable: nil
        }
    }
}

public enum WatchMediaUnavailableReason: String, Codable, Equatable, Sendable {
    /// No connection, and nothing installed for this revision.
    case offlineNotInstalled
    /// Online, but the only link has expired.
    case remoteExpired
    /// Neither installed nor streamable.
    case noSource
    /// Only an older revision is installed, and there is no connection to stream the new one.
    case onlyOlderRevisionInstalled
}

/// Decides what the Watch plays an item from. Pure: the caller passes what is installed, what it
/// can stream, whether it is online, and the item's current revision.
public enum WatchMediaAvailability {
    public static func playability(
        currentRevision: String,
        installs: [WatchMediaInstall],
        remote: (identity: WatchMediaIdentity, remote: WatchMediaRemote, durationMs: Int?)?,
        isOnline: Bool,
        now: Date
    ) -> WatchMediaPlayability {
        if let install = installs.first(where: { $0.identity.sourceRevision == currentRevision }) {
            return .local(install)
        }
        let olderInstalled = !installs.isEmpty
        guard let remote, remote.identity.sourceRevision == currentRevision else {
            if !isOnline, olderInstalled { return .unavailable(.onlyOlderRevisionInstalled) }
            return .unavailable(isOnline ? .noSource : .offlineNotInstalled)
        }
        guard isOnline else {
            return .unavailable(olderInstalled ? .onlyOlderRevisionInstalled : .offlineNotInstalled)
        }
        if let expiresAt = remote.remote.expiresAt, expiresAt <= now {
            return .unavailable(.remoteExpired)
        }
        return .stream(remote.remote, durationMs: remote.durationMs)
    }
}
