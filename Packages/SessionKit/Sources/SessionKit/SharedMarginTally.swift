import Foundation

/// How many Margins other people shared on one item, and how many of those the listener hasn't
/// heard yet (#1792). The Library row says it, so a listener can find where a friend left Margins.
public struct SharedMarginTally: Hashable, Sendable {
    public static let none = SharedMarginTally(total: 0, new: 0)

    public let total: Int
    public let new: Int

    public init(total: Int, new: Int) {
        let total = max(0, total)
        self.total = total
        self.new = min(max(0, new), total)
    }

    public var isEmpty: Bool { total == 0 }

    /// The Library row's line: "3 shared Margins · 1 new", "2 new shared Margins", "1 shared Margin".
    /// Nil when nobody shared a Margin on the item.
    public var libraryLine: String? {
        guard total > 0 else { return nil }
        let noun = total == 1 ? "shared Margin" : "shared Margins"
        if new == total { return "\(total) new \(noun)" }
        if new == 0 { return "\(total) \(noun)" }
        return "\(total) \(noun) · \(new) new"
    }

    /// What VoiceOver says for the line: the words, not the dot.
    public var accessibilityLine: String? {
        guard total > 0 else { return nil }
        let noun = total == 1 ? "Margin" : "Margins"
        let base = "\(total) \(noun) from other listeners"
        return new == 0 ? base : "\(base), \(new) new to you"
    }
}
