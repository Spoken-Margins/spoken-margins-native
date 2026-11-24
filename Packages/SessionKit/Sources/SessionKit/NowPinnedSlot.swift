import Foundation

/// #4715: who may use the Now pane's one pinned slot. A friend's Margin card and a footnote card each keep it first, and
/// while a recording holds navigation nothing else is drawn there. The Speech Recognition card waits on this one rule, so
/// the view and its test read the same three inputs.
public struct NowPinnedSlot: Equatable, Sendable {
    public var friendsMarginCardShowing: Bool
    public var footnoteCardShowing: Bool
    public var recordingIsLocked: Bool

    public init(friendsMarginCardShowing: Bool, footnoteCardShowing: Bool, recordingIsLocked: Bool) {
        self.friendsMarginCardShowing = friendsMarginCardShowing
        self.footnoteCardShowing = footnoteCardShowing
        self.recordingIsLocked = recordingIsLocked
    }

    /// True when the Speech Recognition card may take the slot.
    public var isFreeForSpeechAsk: Bool {
        !friendsMarginCardShowing && !footnoteCardShowing && !recordingIsLocked
    }
}
