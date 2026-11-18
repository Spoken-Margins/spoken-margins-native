import Foundation

/// A show in a follow list (#4046). It matches a subscription by feed key, or by the podcast GUID when both sides
/// have one, so a feed that moved hosts still finds its place in a friend's list.
public struct ListMember: Codable, Equatable, Hashable, Sendable {
    /// `FeedURLKey.make` of the feed link.
    public var feedKey: String
    public var podcastGUID: String?

    public init(feedKey: String, podcastGUID: String? = nil) {
        self.feedKey = feedKey
        self.podcastGUID = Self.normalizedGUID(podcastGUID)
    }

    /// Trimmed, nil when blank. A GUID is compared without case.
    static func normalizedGUID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The feed link is the same, or both sides carry a GUID and it is the same.
    public func matches(feedKey otherKey: String?, podcastGUID otherGUID: String? = nil) -> Bool {
        if let otherKey, otherKey == feedKey { return true }
        // Members decoded from JSON skip `init`, so both sides are trimmed here.
        if let mine = Self.normalizedGUID(podcastGUID), let theirs = Self.normalizedGUID(otherGUID) {
            return mine.caseInsensitiveCompare(theirs) == .orderedSame
        }
        return false
    }
}

/// A named group of followed shows (#4046). A show can sit in several lists, with one row per show on Following.
/// Stored as record kind `follow_list`, which Build 29 and later shipped builds never read, so they ignore it.
public struct FollowList: Codable, Equatable, Sendable, Identifiable {
    /// A UUID. A rename keeps it.
    public let id: String
    public var name: String
    public let createdAt: Date
    /// In the order the listener added them. A show appears once.
    public var members: [ListMember] {
        didSet { members = Self.uniqued(members) }
    }

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), members: [ListMember] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.members = Self.uniqued(members)
    }

    /// A member is a repeat when an earlier one has the same feed key, or the same GUID.
    private static func uniqued(_ members: [ListMember]) -> [ListMember] {
        var keys = Set<String>()
        var guids = Set<String>()
        var kept: [ListMember] = []
        for member in members {
            let guid = ListMember.normalizedGUID(member.podcastGUID)?.lowercased()
            if keys.contains(member.feedKey) || (guid.map(guids.contains) ?? false) { continue }
            keys.insert(member.feedKey)
            if let guid { guids.insert(guid) }
            kept.append(member)
        }
        return kept
    }

    public func contains(feedKey: String?, podcastGUID: String? = nil) -> Bool {
        members.contains { $0.matches(feedKey: feedKey, podcastGUID: podcastGUID) }
    }

    /// Adds the show unless it is already a member. Returns whether the list changed. An existing member that had no GUID
    /// picks one up, so a later import from a friend's file improves the match without adding a row.
    @discardableResult
    public mutating func add(_ member: ListMember) -> Bool {
        if let index = members.firstIndex(where: { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }) {
            guard members[index].podcastGUID == nil, member.podcastGUID != nil else { return false }
            members[index].podcastGUID = member.podcastGUID
            return true
        }
        members.append(member)
        return true
    }

    /// Takes the show out. Returns whether the list changed.
    @discardableResult
    public mutating func remove(feedKey: String?, podcastGUID: String? = nil) -> Bool {
        let before = members.count
        members.removeAll { $0.matches(feedKey: feedKey, podcastGUID: podcastGUID) }
        return members.count != before
    }
}

/// What a typed list name can be (#4046). Names that arrive in a file keep their slashes and are not checked here.
public enum FollowListName {
    public static let maxLength = 40

    public enum Problem: Equatable, Sendable {
        case empty
        case tooLong
        /// "A list name can’t contain a comma or a slash."
        case containsCommaOrSlash
        /// "You already have a list called <name>." Carries the existing list's name.
        case duplicate(existingName: String)

        public var message: String {
            switch self {
            case .empty: "Give the list a name."
            case .tooLong: "A list name can be at most \(FollowListName.maxLength) characters."
            case .containsCommaOrSlash: "A list name can’t contain a comma or a slash."
            case .duplicate(let name): "You already have a list called \(name)."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The name to save: trimmed, with any run of whitespace or control characters inside it made one space.
        case valid(String)
        case invalid(Problem)
    }

    /// Trims, and makes every run of whitespace or control characters inside the name one space, so a pasted line
    /// break can't end up in a chip.
    public static func cleaned(_ raw: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in raw {
            let isBreak = character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
            if isBreak { pendingSpace = !result.isEmpty; continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(character)
        }
        return result
    }

    /// - Parameters:
    ///   - existing: the listener's lists, for the duplicate check.
    ///   - renaming: the list being renamed, which may keep its own name (or change only its case).
    public static func validate(_ raw: String, existing: [FollowList] = [], renaming id: String? = nil) -> Outcome {
        let name = cleaned(raw)
        if name.isEmpty { return .invalid(.empty) }
        if name.unicodeScalars.contains(where: { $0 == "," || $0 == "/" }) { return .invalid(.containsCommaOrSlash) }
        if name.count > maxLength { return .invalid(.tooLong) }
        if let clash = existing.first(where: { $0.id != id && sameName($0.name, name) }) {
            return .invalid(.duplicate(existingName: clash.name))
        }
        return .valid(name)
    }

    /// Trimmed, and case- and diacritic-insensitive. Swift compares canonically equivalent strings (NFC and NFD) as equal.
    public static func sameName(_ a: String, _ b: String) -> Bool {
        cleaned(a).compare(cleaned(b), options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == .orderedSame
    }

    /// The lists in the order the chips show them: locale-aware, case-insensitive, ties by id.
    public static func chipOrder(_ lists: [FollowList]) -> [FollowList] {
        lists.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// Narrows Following's rows to one list's shows (#4046). Friend rows and the row order are not its business: it keeps
/// each row where `FollowingShowRows.build` put it.
public enum FollowListFilter {
    /// - Parameters:
    ///   - subscriptions: resolves each row (its `id` is the subscription's) to a feed key.
    ///   - podcastGUIDs: a subscription's podcast GUID by subscription id, where one is known. Subscriptions don't store
    ///     one yet, so this is empty until a later slice supplies it.
    /// - Returns: the rows and Quiet rows that belong to `list`. A Quiet show stays in its list, in the Quiet group.
    public static func apply(
        rows: [FollowingShowRow],
        quietRows: [FollowingShowRow],
        list: FollowList,
        subscriptions: [FeedSubscription],
        podcastGUIDs: [String: String] = [:]
    ) -> FollowingShowList {
        let subscriptionsByID = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func belongs(_ row: FollowingShowRow) -> Bool {
            guard let subscription = subscriptionsByID[row.id] else { return false }
            return list.contains(feedKey: FeedURLKey.make(subscription.source.canonicalURL), podcastGUID: podcastGUIDs[row.id])
        }
        return FollowingShowList(rows: rows.filter(belongs), quiet: quietRows.filter(belongs))
    }

    /// The lists a show is in, in chip order.
    public static func lists(
        containing subscription: FeedSubscription,
        in lists: [FollowList],
        podcastGUID: String? = nil
    ) -> [FollowList] {
        self.lists(containingFeedKey: FeedURLKey.make(subscription.source.canonicalURL), in: lists, podcastGUID: podcastGUID)
    }

    /// The same, for a caller that has only a feed key (unfollow, an imported file's row).
    public static func lists(
        containingFeedKey key: String?,
        in lists: [FollowList],
        podcastGUID: String? = nil
    ) -> [FollowList] {
        FollowListName.chipOrder(lists).filter { $0.contains(feedKey: key, podcastGUID: podcastGUID) }
    }
}
