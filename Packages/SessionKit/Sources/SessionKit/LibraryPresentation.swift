import Foundation

/// What the Library's "Continue" card offers: the item the listener was in, else the one they heard most recently.
public enum LibraryPresentation {
    public static let continuationSuggestionCutoffPercent = 99

    public static func continueItem(in rows: [LibraryItemRow], activeItemId: String?) -> LibraryItemRow? {
        if let activeItemId,
           let active = rows.first(where: {
               $0.id == activeItemId
                   && !$0.isCompleted
                   && $0.hasContinuationSession
                   && ($0.continuationProgressPercent ?? 0) < continuationSuggestionCutoffPercent
           }) {
            return active
        }

        return rows
            .filter {
                !$0.isCompleted && $0.hasContinuationSession
                    && ($0.continuationProgressPercent ?? 0) > 0
                    && ($0.continuationProgressPercent ?? 0) < continuationSuggestionCutoffPercent
            }
            .sorted {
                let lhs = $0.lastListenedAt ?? .distantPast
                let rhs = $1.lastListenedAt ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
            .first
    }
}
