import SessionKit

extension Gate1AppModel {
    /// The Margins tab's Play button on a friend's Margin (#4447). A Margin with a time in the item starts its moment
    /// as before. One the app matched at a passage of the listener's article or PDF has no time to seek to, so it goes
    /// the way a Skim stop on text does (`startSkimMargin`): to the passage, then the Margin. The button is enabled by
    /// `SharedMarginRow.canPlayFromMarginsList`, which asks `SharedMarginListPlay` for the same two places.
    func playSharedMarginFromMarginsList(_ row: SharedMarginRow) {
        guard SharedMarginListPlay(row.interjection) == .textPassage else { return playSharedMarginMoment(row) }
        guard !rejectNavigationOrSessionMutationWhileRecording("play_shared_margin_from_list") else { return }
        guard row.layer.itemId == selectedItem.id,
              let prompt = importedCommentaryPrompts(includeAnnounced: true).first(where: { $0.interjection.id == row.interjection.id }) else {
            return reportFailure("This shared Margin isn't ready to play here yet.")
        }
        playSharedMarginNow(prompt)
    }
}
