import Foundation

/// The Library row's swipe and long-press actions that the item screen's options menu also offers, so a listener
/// with one hand free doesn't need a precise swipe or a long-press (#1973). Delete is not here: the menu keeps it last.
public enum ItemQuickAction: String, Equatable, Sendable {
    case markComplete
    case markUnfinished
    /// A finished item that still has a friend's new Margins: the second mark complete, for the Margins (#4289).
    case markMarginsHeard
    case playNext
    case addToQueue
    case addToCollection
    case prepareOffline

    /// The one completion action `row` offers: Mark Complete until it is complete, Mark Not Complete only when the
    /// completion was set by hand, and nothing for an item that finished by listening. The item screen's visible
    /// button and its menu entry both read this, so they never disagree (#2393).
    ///
    /// A finished item with a friend's new Margins offers Mark Margins Heard first (#4289): the Library keeps such an
    /// item under Unfinished until they are heard (#4101), and Mark Complete had nothing left to do for it.
    public static func completionAction(for row: LibraryItemRow) -> ItemQuickAction? {
        completionActions(for: row).first
    }

    /// Every completion action `row` offers, most useful first. A finished item can offer two: Mark Margins Heard, and,
    /// when the completion was set by hand, Mark Not Complete. The row's swipe, context menu, VoiceOver actions and the
    /// item screen all read this one list, so they never disagree.
    public static func completionActions(for row: LibraryItemRow) -> [ItemQuickAction] {
        if !row.isCompleted { return [.markComplete] }
        var actions: [ItemQuickAction] = []
        if row.sharedMargins.new > 0 { actions.append(.markMarginsHeard) }
        if row.canMarkUnfinished { actions.append(.markUnfinished) }
        return actions
    }

    /// The actions for `row`, in menu order. The same rules as the row's own context menu.
    public static func actions(for row: LibraryItemRow) -> [ItemQuickAction] {
        var actions = completionActions(for: row)
        actions.append(contentsOf: [.playNext, .addToQueue, .addToCollection])
        if row.offlineState != .readyOffline { actions.append(.prepareOffline) }
        return actions
    }
}
