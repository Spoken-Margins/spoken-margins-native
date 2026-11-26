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
    /// to play it. A Margin at a passage of text is found by the same prompt list a Skim stop uses, which leaves out a
    /// layer the listener turned off, deleted or matched to the wrong source (`isLayerPlaybackEligible`), so the
    /// button follows the layer; a tap there would only fail. A Margin with a time plays its moment whatever the
    /// toggle, as before (`playSharedMarginMoment`). Audit on 1e7362f.
    public static func canPlay(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        SharedMarginAudio.canOffer(interjection) && canGo(interjection, in: layer)
    }

    /// Whether the listener can go to the Margin's place: the place half of `canPlay`, without asking whether it has
    /// anything to play. A friend's Margin that is never spoken (`!SharedMarginAudio.canOffer`) is still a place Skim and
    /// the lists take the listener to, with no voice (#4934). A text passage follows its layer exactly as `canPlay` does:
    /// `isLayerPlaceEligible` is `isLayerPlaybackEligible` without the voice, which would rule out every silent Margin.
    public static func canGo(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        guard let place = SharedMarginListPlay(interjection) else { return false }
        switch place {
        case .moment: return true
        case .textPassage: return SharedMarginPrompts.isLayerPlaceEligible(layer, records: [interjection])
        }
    }

    /// Whether Skim stops at a friend's Margin that is never read aloud, goes to its place and plays on with no voice
    /// (#4934): never spoken (`!SharedMarginAudio.canOffer`), its layer is on, and it has a place. A Margin that can be offered
    /// is a stop of the other kind (a lead-in and its voice), so this is false for it.
    public static func isSilentSkimStop(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        !SharedMarginAudio.canOffer(interjection)
            && SharedMarginPrompts.isLayerPlaceEligible(layer, records: [interjection])
            && canGo(interjection, in: layer)
    }
}
