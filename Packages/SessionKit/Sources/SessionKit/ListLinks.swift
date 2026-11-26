import Foundation

/// A show a list's web address offers and the listener has not yet accepted or turned down (#4046 PR 6).
public struct ProposedShow: Codable, Equatable, Sendable {
    public var member: ListMember
    /// The feed link as the file wrote it, which is what following the show needs.
    public var feedURL: String
    public var title: String
    /// The title of the included list the show came in through, when it came through one.
    public var viaTitle: String?

    public init(member: ListMember, feedURL: String, title: String, viaTitle: String? = nil) {
        self.member = member
        self.feedURL = feedURL
        self.title = title
        self.viaTitle = viaTitle
    }
}

/// What a check found different from the last accepted copy (#4046 PR 6). Nothing in it has been applied: the listener
/// reviews it (PR 7b).
public struct ListProposal: Codable, Equatable, Sendable {
    public var added: [ProposedShow]
    public var removed: [ListMember]
    public var checkedAt: Date

    public init(added: [ProposedShow], removed: [ListMember], checkedAt: Date) {
        self.added = added
        self.removed = removed
        self.checkedAt = checkedAt
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// A list's web address (#4046 PR 6). `own` is a list the listener added by link. `include` is another list their list
/// includes. Stored as record kind `follow_list_link`, which Build 29 and later shipped builds never read, so they ignore
/// it. The record id is the link id.
public struct ListLink: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case own
        case include
    }

    public enum Status: String, Codable, Sendable {
        case ok
        /// Offline, a timeout, a server fault or a refused connection. Worth another try.
        case unreachable
        /// The address answered 404 or 410.
        case gone
        /// The address answered, and it is not an OPML list.
        case notAList
        /// The file, or the list it makes, is over the limits (4 MB, 500 shows).
        case tooBig
    }

    public let id: String
    public let listId: String
    public var url: String
    public var title: String
    public var role: Role
    /// Sent back as `If-None-Match` and `If-Modified-Since`. Kept only for a file with no includes, because a 304 on the
    /// file says nothing about the lists it includes.
    public var etag: String?
    public var lastModified: String?
    /// The last time the file was read, or confirmed unchanged. Not moved by a failed check.
    public var lastCheckedAt: Date?
    public var status: Status
    /// When `status` was last set: the last attempt, whether or not it worked.
    public var statusAt: Date?
    /// The shows the listener has accepted from this address, in the order they were accepted.
    public var acceptedMembers: [ListMember]
    /// The shows the listener turned down. A rejected show is never offered again.
    public var rejectedMembers: [ListMember]
    public var pending: ListProposal?

    public init(
        id: String = UUID().uuidString, listId: String, url: String, title: String, role: Role = .own,
        etag: String? = nil, lastModified: String? = nil, lastCheckedAt: Date? = nil,
        status: Status = .ok, statusAt: Date? = nil,
        acceptedMembers: [ListMember] = [], rejectedMembers: [ListMember] = [], pending: ListProposal? = nil
    ) {
        self.id = id
        self.listId = listId
        self.url = url
        self.title = title
        self.role = role
        self.etag = etag
        self.lastModified = lastModified
        self.lastCheckedAt = lastCheckedAt
        self.status = status
        self.statusAt = statusAt
        self.acceptedMembers = acceptedMembers
        self.rejectedMembers = rejectedMembers
        self.pending = pending
    }

    /// What this link holds after a check that began from an older copy of it: the check's own fields (address, validators,
    /// times, status, proposal) come from `checked`, and everything the listener may have changed while the network
    /// answered (title, role, accepted and rejected shows) stays as it is now. A show the listener turned down in the
    /// meantime is taken out of the proposal, so it is never offered after the tap that refused it.
    public func merging(checked: ListLink) -> ListLink {
        guard checked.id == id else { return self }
        var merged = self
        merged.url = checked.url
        merged.etag = checked.etag
        merged.lastModified = checked.lastModified
        merged.lastCheckedAt = checked.lastCheckedAt
        merged.status = checked.status
        merged.statusAt = checked.statusAt
        if var proposal = checked.pending {
            // A show the listener accepted or turned down meanwhile (the review sheet applied while the network answered, or a
            // 304 that carries the proposal read before the call) is no longer a change to offer.
            proposal.added.removeAll { shown in
                (rejectedMembers + acceptedMembers).contains { $0.matches(feedKey: shown.member.feedKey, podcastGUID: shown.member.podcastGUID) }
            }
            // A show the listener has already taken out by hand is no longer a change to propose.
            proposal.removed.removeAll { gone in
                !acceptedMembers.contains { $0.matches(feedKey: gone.feedKey, podcastGUID: gone.podcastGUID) }
                    || rejectedMembers.contains { $0.matches(feedKey: gone.feedKey, podcastGUID: gone.podcastGUID) }
            }
            merged.pending = proposal.isEmpty ? nil : proposal
        } else {
            merged.pending = nil
        }
        return merged
    }
}

/// Why Following is refreshing (#4046 PR 6). Every caller of the refresh says which, so the rule for list links is one
/// switch over this type and not a flag at each call site. List links are fetched only on a listener's action (the
/// 2026-10-21 rule), never at launch, after a follow or an undo, in the background, or when the app comes forward.
public enum FollowedRefreshTrigger: String, CaseIterable, Sendable {
    /// The listener opened Following.
    case tabAppear
    /// Pull down on Following.
    case pull
    /// The Refresh button Following drew until #4955. Nothing sends it now.
    case refreshButton
    /// **Check now** on a list.
    case checkNow
    /// The launch refresh.
    case startup
    /// After a follow, an import or the first-run picks.
    case afterFollow
    /// After an Undo.
    case undo
    /// The system's background refresh.
    case background
    /// The app came forward. The listener has not opened Following.
    case foreground
    /// After a local change: a dismissed or imported episode, an unfollow, a muted show or a changed policy.
    case localChange

    /// Whether this trigger lets the list checker run. The listener actions (`refreshButton` is no longer sent, #4955).
    public var checksListLinks: Bool {
        switch self {
        case .tabAppear, .pull, .refreshButton, .checkNow: true
        case .startup, .afterFollow, .undo, .background, .foreground, .localChange: false
        }
    }

    /// Whether the check reads every list link now. `tabAppear` reads only the links that are due (`ListLinkSchedule`).
    public var forcesListLinkCheck: Bool {
        switch self {
        case .pull, .refreshButton, .checkNow: true
        case .tabAppear, .startup, .afterFollow, .undo, .background, .foreground, .localChange: false
        }
    }
}

/// Which list links a trigger reads (#4046 PR 6).
public enum ListLinkSchedule {
    /// Opening Following reads a link at most this often, as the shows themselves are read (six hours).
    public static let staleAfter: TimeInterval = 6 * 60 * 60
    /// After a check that failed (offline, 404, not a list), opening Following tries again after this long, so a listener who
    /// opened it offline is not held off for six hours once they are back.
    public static let retryAfterFailure: TimeInterval = 15 * 60

    public static func isDue(_ link: ListLink, trigger: FollowedRefreshTrigger, now: Date) -> Bool {
        guard trigger.checksListLinks else { return false }
        if trigger.forcesListLinkCheck { return true }
        guard let last = link.statusAt else { return true }
        // A clock set back must not hold a link off until it catches up.
        let wait = link.status == .ok ? staleAfter : retryAfterFailure
        return last > now || now.timeIntervalSince(last) >= wait
    }
}

/// Where the checker reads and writes links (#4046 PR 6). The app's store answers it off the main thread.
public protocol ListLinkStoring: Sendable {
    func listLinks() async throws -> [ListLink]
    /// The ids of the lists that still exist. A link whose list was deleted is not checked.
    func existingListIDs() async throws -> Set<String>
    /// Saves a check's result onto the link as it is stored now (`ListLink.merging`). A link deleted meanwhile stays gone.
    func saveChecked(_ link: ListLink) async throws
}
