/// How the Share Margins sheet is opened, and the stage it starts on (#1507).
///
/// The sheet has a stage to choose Margins and a stage to review them, with Share pinned at the bottom of the
/// review stage. The Margins tab and the Export screen open it on the choice. The playback screen's Share is the
/// common case, a listener sending what they just made, so it opens straight on the review: Share on the playback
/// screen, then Share in the sheet is two taps. Choosing Margins stays one tap away ("Back to selection").
public enum ShareSheetEntry: Equatable, Sendable {
    /// Start on the choice of Margins (the Margins tab, the Export screen).
    case chooseMargins
    /// Start on the review with the default selection (the playback screen).
    case reviewDefaults

    /// Whether the sheet starts on the review. With nothing selected there is nothing to review, so it starts on
    /// the choice and the listener can pick something.
    public func startsOnReview(includedCount: Int) -> Bool {
        self == .reviewDefaults && includedCount > 0
    }
}
