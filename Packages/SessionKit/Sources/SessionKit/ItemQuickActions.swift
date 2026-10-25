import Foundation

/// The Library row's swipe and long-press actions that the item screen's options menu also offers, so a listener
/// with one hand free doesn't need a precise swipe or a long-press (#1973). Delete is not here: the menu keeps it last.
public enum ItemQuickAction: String, Equatable, Sendable {
    case markComplete
    case markUnfinished
    case playNext
    case addToQueue
    case addToCollection
    case prepareOffline

    /// The actions for `row`, in menu order. The same rules as the row's own context menu.
    public static func actions(for row: LibraryItemRow) -> [ItemQuickAction] {
        var actions: [ItemQuickAction] = []
        if !row.isCompleted {
            actions.append(.markComplete)
        } else if row.canMarkUnfinished {
            actions.append(.markUnfinished)
        }
        actions.append(contentsOf: [.playNext, .addToQueue, .addToCollection])
        if row.offlineState != .readyOffline { actions.append(.prepareOffline) }
        return actions
    }
}
