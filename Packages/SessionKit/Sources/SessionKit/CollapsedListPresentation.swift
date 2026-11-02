import Foundation

/// A long list that shows its first few rows and opens in place (#3206). Settings > Recently Deleted used to
/// render every deleted item, so twenty of them pushed the rest of Settings out of reach. The rows are already
/// ordered newest first; this says how many to show, how many are behind the control, and what the control says.
public struct CollapsedListPresentation: Equatable, Sendable {
    /// The owner's number: "show two deleted items, then expand".
    public static let collapsedLimit = 2

    public let total: Int
    public let isExpanded: Bool

    public init(total: Int, isExpanded: Bool) {
        self.total = max(0, total)
        self.isExpanded = isExpanded
    }

    /// How many rows to draw: all of them when expanded, else at most `collapsedLimit`.
    public var shownCount: Int {
        isExpanded ? total : min(total, Self.collapsedLimit)
    }

    /// Rows not drawn right now.
    public var hiddenCount: Int { total - shownCount }

    /// The control exists only when there is something to expand: a list of two or fewer has nothing to hide.
    public var showsToggle: Bool { total > Self.collapsedLimit }

    /// "Show all 7" while collapsed, "Show fewer" once open.
    public var toggleTitle: String {
        isExpanded ? "Show fewer" : "Show all \(total)"
    }

    /// Read out with the toggle, so VoiceOver says what the tap reveals.
    public var toggleHint: String {
        isExpanded ? "Shows only the newest \(Self.collapsedLimit)" : "Shows \(hiddenCount) more"
    }
}
