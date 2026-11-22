/// #147: the Margins tab's Share opens the Share Margins sheet for one session of the item. The sheet
/// shares only active Margins on the source (`.item` targets), so a session holding nothing but
/// response Margins must not be picked over an older session that has source Margins.
public enum ItemShareSessionSelection {
    /// The first session, in the order given (newest first), with an active Margin on the source.
    public static func sessionId(
        newestFirst sessionIds: [String],
        margins: (String) throws -> [Interjection]
    ) rethrows -> String? {
        // A session with a Margin a packet can carry comes first. One that holds only Margins with no place (#4233) is
        // still opened when nothing better exists, so the sheet can say why nothing can be shared.
        var fallback: String?
        for sessionId in sessionIds {
            let candidates = try margins(sessionId).filter(isShareable)
            if candidates.contains(where: ShareableMargins.canShare) { return sessionId }
            if fallback == nil, !candidates.isEmpty { fallback = sessionId }
        }
        return fallback
    }

    /// Matches the filter in Gate1AppModel.prepareShareInterjections(candidates:).
    public static func isShareable(_ margin: Interjection) -> Bool {
        margin.status == "active" && margin.targetType == .item
    }
}
