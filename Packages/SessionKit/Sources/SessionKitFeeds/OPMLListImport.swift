import Foundation
import SessionKit

// Lists in an OPML file (#4046, PR 5, the half that needs no screen): which lists a file holds, what importing them
// does to the listener's own lists, and what sharing one list or all follows writes. Nothing here fetches or follows.

/// A list the file holds, as the import screen's "Lists in this file" shows it: "<name> · <n> shows", a switch, and
/// "Adds to your list <name>" when the listener already has one by that name.
public struct OPMLPlannedList: Equatable, Sendable, Identifiable {
    /// Stable within one preview ("list:0", "list:1"...), so the screen can keep a switch per list.
    public var id: String
    /// The name to save: cleaned, and cut to `FollowListName.maxLength` characters.
    public var name: String
    /// Every show the file puts in the list, in file order and once each, whether or not it is followed yet.
    public var members: [ListMember]
    /// The listener's list this one would add to (same name, ignoring case and diacritics), or nil for a new list.
    public var mergesIntoListId: String?

    public var showCount: Int { members.count }
    public var isMerge: Bool { mergesIntoListId != nil }
}

enum OPMLListPlanner {
    /// Overcast writes its own top-level folders, "feeds" and "playlists". They are not the sender's lists.
    static let ignoredFolders = ["feeds", "playlists"]

    static func plan(_ document: OPMLDocument, existingLists: [FollowList]) -> [OPMLPlannedList] {
        var names: [String] = []
        var lists: [FollowList] = []
        for feed in document.feeds {
            guard let key = FeedURLKey.make(feed.feedURL) else { continue }
            let folders = feed.folders.filter { folder in
                !ignoredFolders.contains(folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            let member = ListMember(feedKey: key, podcastGUID: feed.podcastGUID)
            for raw in OPMLListNames.merged(folders, feed.categories) {
                let name = cut(raw)
                guard !name.isEmpty else { continue }
                if let index = names.firstIndex(where: { FollowListName.sameName($0, name) }) {
                    lists[index].add(member)
                } else {
                    names.append(name)
                    lists.append(FollowList(name: name, members: [member]))
                }
            }
        }
        return zip(names, lists).enumerated().map { index, pair in
            OPMLPlannedList(
                id: "list:\(index)", name: pair.0, members: pair.1.members,
                mergesIntoListId: existingLists.first { FollowListName.sameName($0.name, pair.0) }?.id)
        }
    }

    /// A name from a file keeps its slashes (it is not typed in the app) but not more than 40 characters.
    static func cut(_ raw: String) -> String {
        let cleaned = FollowListName.cleaned(raw)
        guard cleaned.count > FollowListName.maxLength else { return cleaned }
        return FollowListName.cleaned(String(cleaned.prefix(FollowListName.maxLength)))
    }
}

/// What "Add lists" or "Add shows and lists" does to the listener's lists once the follows are done.
public struct OPMLListImportResult: Equatable, Sendable {
    /// The lists to save: new ones, and existing ones that gained a show or a GUID. Lists nothing changed are not here.
    public var lists: [FollowList]
    public var createdCount: Int
    public var mergedCount: Int
    /// Switched-on lists left out because none of their shows ended up followed.
    public var skippedEmptyCount: Int
}

public enum OPMLListImporter {
    /// The feed keys that ended up followed: those already followed, and those the import just followed. A feed that
    /// failed, was cancelled or was not ticked is not among them, so a list never names a show the listener does not follow.
    public static func followedFeedKeys(preview: OPMLImportPreview, result: OPMLImportResult?) -> Set<String> {
        var keys = Set(preview.alreadyFollowed.compactMap { FeedURLKey.make($0.feedURL) })
        for candidate in result?.followed ?? [] {
            if let url = candidate.feed?.url, let key = FeedURLKey.make(url) { keys.insert(key) }
        }
        return keys
    }

    /// - Parameters:
    ///   - switchedOn: ids of the planned lists the listener left on.
    ///   - followedFeedKeys: `followedFeedKeys(preview:result:)`.
    ///   - existing: the listener's lists as stored now. A list in the file merges into the one with the same name (ignoring
    ///     case and diacritics), looked up here again so a list made while the screen was open is not duplicated.
    public static func apply(
        _ planned: [OPMLPlannedList],
        switchedOn: Set<String>,
        followedFeedKeys: Set<String>,
        existing: [FollowList],
        now: Date = Date(),
        makeId: () -> String = { UUID().uuidString }
    ) -> OPMLListImportResult {
        var working = existing
        var changedIds: [String] = []
        var created = 0
        var merged = 0
        var skipped = 0
        for list in planned where switchedOn.contains(list.id) {
            let members = list.members.filter { followedFeedKeys.contains($0.feedKey) }
            guard !members.isEmpty else { skipped += 1; continue }
            if let index = working.firstIndex(where: { FollowListName.sameName($0.name, list.name) }) {
                var changed = false
                for member in members where working[index].add(member) { changed = true }
                if changed {
                    if !changedIds.contains(working[index].id) { changedIds.append(working[index].id); merged += 1 }
                }
            } else {
                let made = FollowList(id: makeId(), name: list.name, createdAt: now, members: members)
                working.append(made)
                changedIds.append(made.id)
                created += 1
            }
        }
        let lists = changedIds.compactMap { id in working.first { $0.id == id } }
        return OPMLListImportResult(lists: lists, createdCount: created, mergedCount: merged, skippedEmptyCount: skipped)
    }
}

extension OPMLExporter {
    /// "Following.opml": everything the listener follows, with their lists.
    public static let allFollowsFileName = "Following.opml"

    /// Everything followed, with each show's lists. Private feeds are left out (`OPMLExport.withheldPrivateCount` counts them).
    public static func exportAllFollows(
        _ subscriptions: [FeedSubscription], lists: [FollowList], podcastGUIDs: [String: String] = [:], createdAt: Date = Date()
    ) -> OPMLExport {
        export(subscriptions, title: "Spoken Margins follows", createdAt: createdAt, lists: lists, podcastGUIDs: podcastGUIDs)
    }

    /// One list, as a file any podcast app can open: its shows, each with the list as its `category`, titled with the
    /// list's name. A show belongs by feed link, or by GUID when both sides have one. Private feeds are left out.
    public static func exportList(
        _ list: FollowList, subscriptions: [FeedSubscription], podcastGUIDs: [String: String] = [:], createdAt: Date = Date()
    ) -> OPMLExport {
        let members = subscriptions.filter { subscription in
            list.contains(
                feedKey: FeedURLKey.make(subscription.source.canonicalURL) ?? subscription.source.canonicalURL,
                podcastGUID: podcastGUIDs[subscription.id])
        }
        return export(members, title: list.name, createdAt: createdAt, lists: [list], podcastGUIDs: podcastGUIDs)
    }

    /// "<list>.opml", safe as a file name: no slash, colon or other character a file system or share sheet trips on.
    public static func fileName(forList list: FollowList) -> String {
        // By character, not by scalar: an emoji's joiner is a control-like scalar inside one character.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.illegalCharacters)
        let replaced = list.name.map { character -> Character in
            character.unicodeScalars.allSatisfy { forbidden.contains($0) || ($0.value < 0x20) || $0.value == 0x7F } ? " " : character
        }
        var name = FollowListName.cleaned(String(replaced))
        while name.hasPrefix(".") { name.removeFirst() }
        name = FollowListName.cleaned(name)
        return (name.isEmpty ? "List" : name) + ".opml"
    }
}
