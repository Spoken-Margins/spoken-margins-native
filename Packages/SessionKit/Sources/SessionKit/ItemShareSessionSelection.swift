/// #147: the Margins tab's Share opens the Share Margins sheet for one session of the item. The sheet
/// shares only active Margins on the source (`.item` targets), so a session holding nothing but
/// response Margins must not be picked over an older session that has source Margins.
public enum ItemShareSessionSelection {
    /// The first session, in the order given (newest first), with an active Margin on the source.
    public static func sessionId(
        newestFirst sessionIds: [String],
        margins: (String) throws -> [Interjection]
    ) rethrows -> String? {
        for sessionId in sessionIds where try margins(sessionId).contains(where: isShareable) {
            return sessionId
        }
        return nil
    }

    /// The same test the Share Margins sheet applies to its candidates.
    public static func isShareable(_ margin: Interjection) -> Bool {
        margin.status == "active" && margin.targetType == .item
    }
}
