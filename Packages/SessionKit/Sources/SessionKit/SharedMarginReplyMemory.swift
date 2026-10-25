import Foundation

/// Which shared Margin a new Margin answers when the listener did not press Reply (#473, owner 2026-10-25).
/// A Margin recorded while a friend's shared Margin plays, or soon after it ends, is a reply to it; the listener can
/// switch it to an independent Margin (`MarginReplyChoice`). This is the decision, apart from the app model, so it
/// can be tested without a player: the model tells it when a shared Margin's voice starts and stops.
public struct SharedMarginReplyMemory: Equatable, Sendable {
    /// How long after a shared Margin's voice ends that a new Margin still answers it. Long enough to take a breath
    /// and press Add a Margin, short enough that a thought a minute later stands alone.
    public static let window: TimeInterval = 20

    private struct Heard: Equatable, Sendable {
        let draft: MarginReplyDraft
        let itemId: String
        var endedAt: Date?
    }

    private var heard: Heard?

    public init() {}

    /// A shared Margin's voice started. It replaces whatever was heard before: two Margins in a row, the later one is answered.
    public mutating func began(_ draft: MarginReplyDraft, itemId: String) {
        heard = Heard(draft: draft, itemId: itemId, endedAt: nil)
    }

    /// The voice stopped, finished or was cut. Only the first end counts, so a stop path that runs twice cannot stretch the window.
    public mutating func ended(at date: Date) {
        guard var current = heard, current.endedAt == nil else { return }
        current.endedAt = date
        heard = current
    }

    /// The Margin a Margin started at `now` on `itemId` answers, if any.
    public func reply(forItem itemId: String, at now: Date) -> MarginReplyDraft? {
        guard let heard, heard.itemId == itemId else { return nil }
        guard let endedAt = heard.endedAt else { return heard.draft } // still sounding
        return max(0, now.timeIntervalSince(endedAt)) <= Self.window ? heard.draft : nil
    }
}

/// The reply a Margin starts with and whether the listener switched it to independent (#473). The suggestion is kept
/// so the switch can be undone, before or after saving.
public struct MarginReplyChoice: Equatable, Sendable {
    public private(set) var suggested: MarginReplyDraft?
    public private(set) var isIndependent = false

    public init(suggested: MarginReplyDraft? = nil) {
        self.suggested = suggested
    }

    /// What the Margin is saved as a reply to.
    public var effective: MarginReplyDraft? { isIndependent ? nil : suggested }

    /// False when there was never anything to answer.
    public var canToggle: Bool { suggested != nil }

    public mutating func toggle() {
        guard canToggle else { return }
        isIndependent.toggle()
    }

    /// The line the recording, writing and Margin screens show: whom the Margin answers, or that it no longer does.
    public var caption: String? {
        guard let suggested else { return nil }
        return isIndependent ? "Independent Margin, not a reply to \(suggested.parentSenderLabel)" : suggested.caption
    }

    /// The control that switches it, named for what it does: the words carry the state, not colour alone.
    public var switchTitle: String? {
        guard let suggested else { return nil }
        return isIndependent ? "Reply to \(suggested.parentSenderLabel)" : "Make independent"
    }
}
