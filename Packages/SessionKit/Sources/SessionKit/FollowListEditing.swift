import Foundation

/// The edits a listener makes to follow lists on Following (#4046 PR 2), as pure functions over the lists as stored,
/// so the sheet, the chip menu and the tests all follow one rule. Names go through `FollowListName.validate`.
public enum FollowListEditing {
    public enum CreateOutcome: Equatable, Sendable {
        case created(FollowList)
        case invalid(FollowListName.Problem)
    }

    public enum RenameOutcome: Equatable, Sendable {
        case renamed(FollowList)
        /// The list is gone (deleted on another path while the alert was open).
        case missing
        case invalid(FollowListName.Problem)
    }

    /// The list member for a followed show: its feed link as `FeedURLKey` writes it, which is what `FollowListFilter`
    /// matches rows by. A link with no host (not a feed at all) keeps its text, so the tick is not lost.
    public static func member(for subscription: FeedSubscription, podcastGUID: String? = nil) -> ListMember {
        let link = subscription.source.canonicalURL
        return ListMember(feedKey: FeedURLKey.make(link) ?? link, podcastGUID: podcastGUID)
    }

    /// A new list, holding `member` when the listener made it from a show's sheet ("the new list is ticked for this
    /// show").
    public static func creating(
        name: String,
        adding member: ListMember? = nil,
        existing: [FollowList],
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> CreateOutcome {
        switch FollowListName.validate(name, existing: existing) {
        case .invalid(let problem):
            return .invalid(problem)
        case .valid(let cleaned):
            return .created(FollowList(id: id, name: cleaned, createdAt: now, members: member.map { [$0] } ?? []))
        }
    }

    /// The same list under a new name. The id and the members stay, so a rename never changes what a show belongs to.
    public static func renaming(id: String, to name: String, in lists: [FollowList]) -> RenameOutcome {
        guard var list = lists.first(where: { $0.id == id }) else { return .missing }
        switch FollowListName.validate(name, existing: lists, renaming: id) {
        case .invalid(let problem):
            return .invalid(problem)
        case .valid(let cleaned):
            list.name = cleaned
            return .renamed(list)
        }
    }
}

/// The words Following's lists use on the screens PR 2 adds. "List" is the only word the listener sees (Default 1).
public enum FollowListWords {
    /// The Show screen's Lists row value: "News, Commute" in chip order, or "None".
    public static func rowValue(_ lists: [FollowList]) -> String {
        let names = FollowListName.chipOrder(lists).map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// The sheet's title: "Lists for Hard Fork", or "Lists" when the show has no name.
    public static func sheetTitle(showTitle: String?) -> String {
        guard let name = showTitle.map(FollowListName.cleaned), !name.isEmpty else { return "Lists" }
        return "Lists for \(name)"
    }

    /// "Every show in News is Quiet." It sits above the Quiet section, which starts open.
    public static func allQuietNote(listName: String) -> String { "Every show in \(listName) is Quiet." }

    /// What an empty list says on Following and on its own screen. The **Add shows** button sits under it.
    public static func emptyListText(listName: String) -> String { "No shows in \(listName) yet" }

    /// The Lists screen's title, and the toolbar button's label.
    public static let listsTitle = "Lists"

    /// "3 shows", "1 show".
    public static func showCount(_ count: Int) -> String { count == 1 ? "1 show" : "\(count) shows" }

    public static let emptyListsTitle = "No lists yet"
    public static let emptyListsDetail = "Group the shows you follow. A show can be in several lists. Tap a list on Following to see only its shows, or share it with a friend."

    /// "Add shows to News".
    public static func addShowsTitle(listName: String) -> String { "Add shows to \(listName)" }

    /// A list's own screen, section "Shows (3)".
    public static func showsHeader(count: Int) -> String { "Shows (\(count))" }

    /// "Delete News?"
    public static func deleteQuestion(listName: String) -> String { "Delete \(listName)?" }

    /// Under the delete question: a list only groups shows.
    public static let deleteMessage = "Every show in it stays followed."

    /// The unfollow confirmation's line. Unfollowing takes the show out of every list (Default 19), and says so.
    public static func unfollowMessage(inAList: Bool) -> String {
        inAList
            ? "Everything already in your Library will be kept. It also leaves your lists."
            : "Everything already in your Library will be kept."
    }

    /// The banner after Unfollow on a show's screen. A show that was in lists says it left them, and Undo puts it back
    /// in them.
    public static func unfollowedBanner(showTitle: String?, wasInAList: Bool) -> String {
        let base = FollowingRowActions.unfollowedMessage(showTitle: showTitle)
        return wasInAList ? base + " It also left your lists." : base
    }
}
