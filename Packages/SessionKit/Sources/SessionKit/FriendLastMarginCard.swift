import Foundation

/// The card after a friend's last Margin has played (#3247). The owner's words (2026-11-02): "That was Cole's last Margin.
/// To answer him, add a Margin of your own." No new buttons; the card holds the pinned slot, and the answer is made with
/// the player's own button. "Him" would be wrong for some senders, so the second line names the sender again, or says
/// "your friend" / "your friends" when it has no name to use.
extension PinnedMarginCard {
    /// The card for an item that holds friends' Margins, once one has been heard and none is ahead. Nil on the listener's
    /// own items (no live friend layer), before any Margin was heard, and while `answerSaved` holds the slot: the news that
    /// a saved Margin can be sent outranks the news that the friend's Margins are over.
    ///
    /// The caller decides that nothing is ahead (the pinned card's own `nextSharedMargin`); this decides the words.
    public static func friendsLast(
        now: Date,
        heardAMargin: Bool,
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer]
    ) -> PinnedMarginCard? {
        guard heardAMargin else { return nil }
        let live = layers.filter { $0.deletedAt == nil }.sorted { $0.importedAt < $1.importedAt }
        guard !live.isEmpty else { return nil }
        guard answerSaved(now: now, localMargins: localMargins, layers: layers) == nil else { return nil }
        // One sender per name; the senders with no name count once between them, since nothing tells them apart.
        var names: [String] = []
        var hasUnnamed = false
        for layer in live {
            if let name = SharedPacketArrival.senderName(layer.displayLabel) {
                if !names.contains(name) { names.append(name) }
            } else {
                hasUnnamed = true
            }
        }
        let senders = names.count + (hasUnnamed ? 1 : 0)
        let subject: Subject = senders == 1 ? .friend(names.first) : .friend(nil)
        return PinnedMarginCard(subject: subject, stage: .lastMargin(senders: senders))
    }
}

/// How the player's Share opens (#3247, 2026-11-03): on a friend's item where the listener has answered, with those
/// answers already picked and changeable, as the Margins screen's "Send replies" does; anywhere else as it always has.
public enum PlaybackShareStart: Equatable, Sendable {
    /// Open "Send replies to <friend>": the answers are chosen, the listener's other new Margins are listed and left out.
    case friendAnswersPicked(ReplyBackOffer)
    /// Open the ordinary share sheet with the default Margins.
    case defaults

    /// A friend's answer is a Margin the listener made as a reply to one of the friend's (`replyTo`). A Margin made on a
    /// friend's item that answers nothing leaves the sheet as it was, with every Margin picked, so Share never opens
    /// with nothing chosen.
    public static func start(localMargins: [Interjection], layers: [ImportedCommentaryLayer]) -> PlaybackShareStart {
        guard let offer = ReplyBackOffer.make(localMargins: localMargins, layers: layers), !offer.replies.isEmpty else {
            return .defaults
        }
        return .friendAnswersPicked(offer)
    }
}
