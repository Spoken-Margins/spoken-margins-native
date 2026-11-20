import Foundation

/// How many Margins other people shared on one item, and how many of those the listener hasn't
/// heard yet (#1792). The Library row says it, so a listener can find where a friend left Margins.
public struct SharedMarginTally: Hashable, Sendable {
    public static let none = SharedMarginTally(total: 0, new: 0)

    public let total: Int
    public let new: Int
    /// Who sent them (#3794): the friends whose Margins these are, merged by sender, as `SharedMarginTally.Sender`.
    /// Empty from a caller that doesn't read them; `senderLine` then says "a friend".
    public let senders: [Sender]
    /// How many of `total` are replies to the listener's own Margins (#3889's rule), for `senderLine`'s words.
    public let replies: Int

    public init(total: Int, new: Int, senders: [Sender] = [], replies: Int = 0) {
        let total = max(0, total)
        self.total = total
        self.new = min(max(0, new), total)
        // Names read in a second statement can disagree with the count if a write came between them; then the names
        // are dropped and the line says "a friend", rather than naming people for Margins that are not there.
        let merged = Self.mergedSenders(senders)
        self.senders = merged.reduce(0) { $0 + $1.count } == total ? merged : []
        self.replies = min(max(0, replies), total)
    }

    public var isEmpty: Bool { total == 0 }
}
