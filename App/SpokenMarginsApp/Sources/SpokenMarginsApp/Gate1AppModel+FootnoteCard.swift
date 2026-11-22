import Foundation
import SessionKit

/// The Footnote card on the Now screen (#3777, Design PR 5): which note, if any, the narrator is reading where it is
/// cited. The words are `FootnoteCard` and the plan rules behind it are `FootnoteNoteControls`, both in SessionKit; this
/// reads the player into them. It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// Whether the card could be showing: the open item is the one playing, it is not a podcast, and the on-device voice
    /// (the only player with note chunks) is reading a plan that has notes in it. The card's view polls the player only
    /// while this is true, so an article without notes, or any other item, costs nothing.
    var footnoteCardMayShow: Bool {
        guard !selectedItem.isNativeAudio, snapshot.itemId == selectedItem.id,
              snapshot.status.isPlaybackActive || snapshot.status == .paused,
              let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else { return false }
        return client.hasFootnoteAsides
    }

    /// The card for the note being read, or nil. A friend's pinned card wins and the note is not shown for that listen at
    /// all: it does not queue behind the friend's card, and the note stays in the notes chapter (Design, Screens).
    var footnoteCard: FootnoteCard? {
        // The player's answer comes first: `pinnedMarginCard` builds a good deal, and a note is the rare case.
        guard footnoteCardMayShow, let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
              let card = client.currentFootnoteCard(), pinnedMarginCard == nil else { return nil }
        return card
    }

    /// "Reading" is in the card's header while the note's own words are playing; a note paused on is shown without it.
    var footnoteCardIsReading: Bool { snapshot.status.isPlaybackActive }
}
