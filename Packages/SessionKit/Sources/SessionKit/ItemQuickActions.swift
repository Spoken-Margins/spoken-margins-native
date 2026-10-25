import Foundation

/// The Library row's swipe and long-press actions that the item screen's options menu also offers, so a listener
/// with one hand free doesn't need a precise swipe or a long-press (#1973). Delete is not here: the menu keeps it last.
public enum ItemQuickAction: String, Equatable, Sendable {
    case markComplete
    case markUnfinished
    case addToCollection
    case prepareOffline

    /// The one completion action `row` offers: Mark Complete until it is complete, Mark Not Complete only when the
    /// completion was set by hand, and nothing for an item that finished by listening. The item screen's visible
    /// button and its menu entry both read this, so they never disagree (#2393).
    public static func completionAction(for row: LibraryItemRow) -> ItemQuickAction? {
        if !row.isCompleted { return .markComplete }
        return row.canMarkUnfinished ? .markUnfinished : nil
    }

    /// The actions for `row`, in menu order. The same rules as the row's own context menu.
    public static func actions(for row: LibraryItemRow) -> [ItemQuickAction] {
        var actions: [ItemQuickAction] = []
        if let completion = completionAction(for: row) { actions.append(completion) }
        actions.append(.addToCollection)
        if row.offlineState != .readyOffline { actions.append(.prepareOffline) }
        return actions
    }
}
