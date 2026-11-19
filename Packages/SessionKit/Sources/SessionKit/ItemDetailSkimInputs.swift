import Foundation

extension ItemDetailState {
    /// True when something Skim's stop list reads from the item differs between `self` and `other` (#4447).
    ///
    /// Skim stops at the next chapter or Margin, and works that out from the playing item's chapters, scenes and the
    /// records of each friend's layer (a layer with no loaded records is not playable, so its Margins are no stop).
    /// The item detail loads after the item opens, often while the source sits paused, so a change to any of these
    /// has to recompute the Skim arrows: nothing else will until the playhead moves. Anything else on the item (its
    /// title, dates, status) can't move a stop, and says false so a refresh that changes only those costs nothing.
    public func skimStopInputsDiffer(from other: ItemDetailState) -> Bool {
        id != other.id
            || chapters != other.chapters
            || mediaChapters != other.mediaChapters
            || listeningMapScenes != other.listeningMapScenes
            || importedCommentaryInterjections != other.importedCommentaryInterjections
    }
}
