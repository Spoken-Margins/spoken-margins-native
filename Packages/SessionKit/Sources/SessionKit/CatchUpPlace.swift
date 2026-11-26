import Foundation

/// The re-listen's place after a catch-up run that ended paused (#5238). A run on a finished item resumes the listener's
/// re-listen, plays the replies and pauses after the last one, so "Add a Margin" anchors right after it (#4785). Without
/// this the session is saved at the reply and the next Continue starts there. Now the place stays owed, held where the
/// run stopped, and comes back on the next Play or leave while the source is still there; a listener who moved the
/// playhead first keeps their own place. The note is the existing `ReviewReturnPlace`, so no new store or flag.
public enum CatchUpPlace {
    /// How far the source can stand from where the run stopped and still be "there": a saved Margin's rejoin moves it to
    /// a few seconds before the anchor (`MarginRejoin`), and anything further is the listener's own move.
    public static let stillThereMs = 3_000

    /// The note to keep at the run's natural end, held where the source stopped, or nil when nothing is owed. Only a place
    /// the run pulled the listener back from (a Margin had the floor while it stayed owed: `passedAMargin`) and that is
    /// ahead of where the run stopped is owed: a re-listen behind the reply carries on from the reply, as ordinary reviews
    /// do, which keeps round two from going back to the old reply.
    public static func hold(_ note: ReviewReturnPlace?, sourceAtMediaTimeMs: Int?) -> ReviewReturnPlace? {
        guard let note, note.passedAMargin == true, let sourceAt = sourceAtMediaTimeMs,
              note.returnToMediaTimeMs - sourceAt > ReviewReturnPlace.alreadyThereMs else { return nil }
        return note.held(at: sourceAt)
    }

    public enum Outcome: Equatable, Sendable {
        /// No held place for this item: nothing to do.
        case nothing
        /// The source is still where the run stopped: move it to the listener's place.
        case giveBack(toMediaTimeMs: Int)
        /// The source moved since (or can't be read): the place is the listener's own now, so the note goes.
        case drop
    }

    /// What a held note is worth with the source at `sourceAtMediaTimeMs` on `itemId`: on Play, Continue, another item,
    /// closing the player or a relaunch. An ordinary review's note (not held) is not this rule's to touch.
    public static func settle(_ note: ReviewReturnPlace?, itemId: String?, sourceAtMediaTimeMs: Int?) -> Outcome {
        guard let note, let heldAt = note.heldAtMediaTimeMs, note.itemId == itemId else { return .nothing }
        guard let sourceAt = sourceAtMediaTimeMs, abs(sourceAt - heldAt) <= stillThereMs else { return .drop }
        return .giveBack(toMediaTimeMs: note.returnToMediaTimeMs)
    }
}
