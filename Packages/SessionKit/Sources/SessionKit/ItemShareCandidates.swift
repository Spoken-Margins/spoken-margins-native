/// What the Share Margins sheet starts with for an item (#4688): every Margin of the listener's own on it that a packet
/// could carry, from every listening pass, in the order they sit in the item.
///
/// The sheet used to hold one pass (`ItemShareSessionSelection`), so after "Replay" on a finished episode the first
/// listen's Margins could not be reached. The packet has no session field, so mixing passes needs no new packet shape.
public struct ItemShareCandidates: Equatable, Sendable {
    /// The drafts, in source order.
    public let margins: [Interjection]
    /// The newest pass with a Margin a packet can carry, by `ItemShareSessionSelection.sessionId`'s rule; Export reads it.
    public let sessionId: String?

    /// `marginsBySession`: each pass's Margins, read once. `sessionIdsNewestFirst`: the item's passes, newest first.
    /// `mediaSourceType`: `Item.media?.sourceType.rawValue`, which says whether Margins order by media time or by text.
    public static func make(
        sessionIdsNewestFirst: [String],
        marginsBySession: [String: [Interjection]],
        mediaSourceType: String?
    ) -> ItemShareCandidates {
        // Keyed by session and id: every pass numbers its Margins from "ij-001", so `id` alone let a replay's first
        // Margin hide the first listen's (#4688, Test Desk 2026-11-23).
        var seen = Set<String>()
        var margins: [Interjection] = []
        for sessionId in sessionIdsNewestFirst {
            for margin in marginsBySession[sessionId] ?? [] where ItemShareSessionSelection.isShareable(margin) {
                if seen.insert(margin.sessionScopedId).inserted { margins.append(margin) }
            }
        }
        // The item-wide Markdown export's order, so Share and that export never disagree.
        let timed = MarginMarkdownShare.recordedMediaSources.contains(mediaSourceType ?? "")
        margins.sort {
            let (lhs, rhs) = (MarginMarkdownShare.sourceOrder($0, timed: timed), MarginMarkdownShare.sourceOrder($1, timed: timed))
            return lhs != rhs ? lhs < rhs : ($0.createdAt, $0.sessionScopedId) < ($1.createdAt, $1.sessionScopedId)
        }
        let sessionId = ItemShareSessionSelection.sessionId(newestFirst: sessionIdsNewestFirst) { marginsBySession[$0] ?? [] }
        return ItemShareCandidates(margins: margins, sessionId: sessionId)
    }
}
