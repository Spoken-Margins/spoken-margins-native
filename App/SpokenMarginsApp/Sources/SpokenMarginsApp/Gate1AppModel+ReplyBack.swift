import Foundation
import SessionKit

/// Sending replies back to the friend who shared (#3221). What the offer holds and how the friend is named is
/// decided in SessionKit (`ReplyBackOffer`); this file reads what the Margins screen already holds and opens the
/// share sheet on it.
extension Gate1AppModel {
    /// The "Send replies to <friend>" offer for an item, or nil when the listener has made no Margin on it since
    /// they imported a friend's packet. Read from the rows the Margins screen already published, so it adds no
    /// store read to the screen.
    func replyBackOffer(itemID: String) -> ReplyBackOffer? {
        var layers: [String: ImportedCommentaryLayer] = [:]
        for row in sharedMarginRows where row.layer.itemId == itemID { layers[row.layer.id] = row.layer }
        guard !layers.isEmpty else { return nil }
        return ReplyBackOffer.make(
            localMargins: marginRows.map(\.interjection).filter { $0.itemId == itemID },
            layers: Array(layers.values)
        )
    }

    /// Opens the Share sheet as "Send replies to <friend>": the replies are included, the listener's other new
    /// Margins are listed and left out, and nothing the friend sent is in it.
    func openReplyBackExport(itemID: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_reply_back") else { return }
        guard let offer = replyBackOffer(itemID: itemID) else {
            return reportFailure("You haven't made a Margin on this item since you opened your friend's.")
        }
        do {
            selectedItem = try loadItemDetail(id: itemID, store: requireStore())
            prepareShareInterjections(candidates: offer.candidates, replyBack: offer)
            if isSharingInterjectionsPresented { sharingState.draftsPreparedForExport = true }
        } catch { reportFailure(error, context: "Open reply export failed") }
    }
}
