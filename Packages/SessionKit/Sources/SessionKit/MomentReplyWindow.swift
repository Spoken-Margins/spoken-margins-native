import Foundation

/// The reply a new Margin suggests when a Margin moment or review plays a friend's voice (#5238). The owner's rule
/// (2026-11-09): a Margin made while a friend's Margin plays, or within 20 seconds after it ends, is saved as a reply.
/// Only the shared-Margin player fed that rule; voices played by the moment's own player never opened the window.
public enum MomentReplyWindow {
    /// The draft for the friend Margin whose moment id (`SharedMarginReview.marginId(layerId:interjectionId:)`) is
    /// `marginId`, found in `rows`. Nil for the listener's own Margin or an id no row has.
    public static func draft(forMarginId marginId: String, rows: [SharedMarginRow]) -> MarginReplyDraft? {
        guard let row = rows.first(where: {
            SharedMarginReview.marginId(layerId: $0.layer.id, interjectionId: $0.interjection.id) == marginId
        }) else { return nil }
        return MarginReplyDraft(parent: row.interjection, in: row.layer)
    }
}
