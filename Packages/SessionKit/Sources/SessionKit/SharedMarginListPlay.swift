import Foundation

/// How the playback screen's Margins tab plays a friend's Margin (#4447). A podcast Margin has a time in the
/// listener's copy, so its Play button starts the moment player there. An article or PDF Margin the app matched in
/// the listener's text has only a character offset: it has no time to seek to, so it goes the way a Skim stop on text
/// does, to the passage and then the Margin. Before this the Margins tab asked only for a time, so a friend's Margin
/// on an article was listed at its passage with a dead Play button (`SharedMarginReplyPlace` already knew both places).
public enum SharedMarginListPlay: Equatable, Sendable {
    /// A time in the item: the moment player (lead-in, the friend's voice, then the item).
    case moment
    /// A matched passage of text: jump to it and play the Margin there.
    case textPassage

    public init?(_ interjection: ImportedCommentaryInterjection) {
        switch SharedMarginReplyPlace(interjection) {
        case .media: self = .moment
        case .text: self = .textPassage
        case nil: return nil
        }
    }

    /// Whether the Margins tab's Play button is enabled: something to play (`SharedMarginAudio.canOffer`) and a place
    /// to play it.
    public static func canPlay(_ interjection: ImportedCommentaryInterjection) -> Bool {
        SharedMarginAudio.canOffer(interjection) && SharedMarginListPlay(interjection) != nil
    }
}
