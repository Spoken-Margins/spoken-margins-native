import Foundation
import SessionKit

/// What the friend's arrival rebuild adds around a friend's item (#3247). The words and the rules are in SessionKit
/// (`PinnedMarginCard.answerSaved`, `PinnedMarginCard.friendsLast`, `PlaybackShareStart`); this reads the open item's
/// rows, which the Margins screen already holds, so it adds no store read.
extension Gate1AppModel {
    /// The open item's live friend layers and the listener's own Margins on it.
    private var friendItemFacts: (layers: [ImportedCommentaryLayer], localMargins: [Interjection]) {
        let itemID = selectedItem.id
        var layers: [String: ImportedCommentaryLayer] = [:]
        for row in sharedMarginRows where row.layer.itemId == itemID { layers[row.layer.id] = row.layer }
        return (Array(layers.values), marginRows.filter { $0.interjection.itemId == itemID }.map(\.interjection))
    }

    /// The "saved, tap Share to send it" card, or nil off a friend's item or once its window is over.
    var friendAnswerSavedCard: PinnedMarginCard? {
        let facts = friendItemFacts
        guard !facts.layers.isEmpty else { return nil }
        return PinnedMarginCard.answerSaved(now: Date(), localMargins: facts.localMargins, layers: facts.layers)
    }

    /// "That was Cole's last Margin. To answer him, add a Margin of your own." The pinned card asks only when no friend's
    /// Margin is ahead; a Margin counts as heard once the offer queue has announced it.
    var friendLastMarginCard: PinnedMarginCard? {
        let facts = friendItemFacts
        guard !facts.layers.isEmpty else { return nil }
        let heard = importedCommentaryPrompts(includeAnnounced: true).contains { sharedMarginOffers.announcedIDs.contains($0.id) }
        return PinnedMarginCard.friendsLast(now: Date(), heardAMargin: heard, localMargins: facts.localMargins, layers: facts.layers)
    }

    /// The player's Share: on a friend's item where the listener has answered, "Send replies to <friend>" with the answers
    /// picked and changeable; on any other item the share sheet it always opened.
    func openPlaybackShareStartingWithFriendAnswers() {
        let facts = friendItemFacts
        switch PlaybackShareStart.start(localMargins: facts.localMargins, layers: facts.layers) {
        case .friendAnswersPicked: openReplyBackExport(itemID: selectedItem.id)
        case .defaults: openMarginItemExport(itemID: selectedItem.id, entry: .reviewDefaults)
        }
    }
}
