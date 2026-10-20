import Foundation

/// The shared-packet review slot (#2122): one review shows at a time, and a packet opened while one is showing
/// waits its turn instead of replacing it. Ending a review (an import finishing, or Cancel) is tied to the
/// review that started it, so an import that finishes after the screen has moved on never clears another
/// packet's review.
public struct PacketReviewQueue<Review: Identifiable> {
    public enum Placement: Equatable {
        case showing
        /// Behind the showing review; `position` 1 is next.
        case waiting(position: Int)
    }

    public private(set) var showing: Review?
    public private(set) var waiting: [Review] = []

    public init() {}

    @discardableResult
    public mutating func offer(_ review: Review) -> Placement {
        guard showing != nil else {
            showing = review
            return .showing
        }
        waiting.append(review)
        return .waiting(position: waiting.count)
    }

    public func isShowing(_ id: Review.ID) -> Bool {
        showing?.id == id
    }

    /// The review `id` is over. When it is the one showing, the next waiting review takes its place; a waiting
    /// one just leaves the line; anything else changes nothing. Returns whether `id` was the one showing.
    @discardableResult
    public mutating func finish(_ id: Review.ID) -> Bool {
        if showing?.id == id {
            showing = waiting.isEmpty ? nil : waiting.removeFirst()
            return true
        }
        waiting.removeAll { $0.id == id }
        return false
    }

    /// A rebuilt copy of the showing review (after Add Source), or a write from the views. Waiting reviews stay.
    public mutating func replaceShowing(with review: Review?) {
        showing = review
    }
}
