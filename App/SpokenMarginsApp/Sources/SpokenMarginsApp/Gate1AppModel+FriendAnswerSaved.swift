import Foundation
import SessionKit

/// The pinned card's words after a friend saves a Margin (#3247). What it says and when is `PinnedMarginCard.answerSaved`
/// in SessionKit; this reads the open item's rows, which the Margins screen already holds, so it adds no store read.
extension Gate1AppModel {
    /// The "saved, tap Share to send it" card, or nil off a friend's item or once its window is over.
    var friendAnswerSavedCard: PinnedMarginCard? {
        let itemID = selectedItem.id
        var layers: [String: ImportedCommentaryLayer] = [:]
        for row in sharedMarginRows where row.layer.itemId == itemID { layers[row.layer.id] = row.layer }
        guard !layers.isEmpty else { return nil }
        return PinnedMarginCard.answerSaved(
            now: Date(),
            localMargins: marginRows.filter { $0.interjection.itemId == itemID }.map(\.interjection),
            layers: Array(layers.values))
    }
}
