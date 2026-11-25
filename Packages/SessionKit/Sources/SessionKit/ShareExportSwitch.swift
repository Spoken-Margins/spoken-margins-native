import Foundation

/// One tap between Share and Export (#5306). The owner asked for "an easy way for the user to switch between the two
/// with a button" (2026-11-24). Share stays a person and Export stays yourself (#3211): this only crosses between the
/// two doors, for the same item, and neither button sends, builds or writes anything on its own.
public enum ShareExportSwitch {
    /// The Share Margins sheet's button to Export. It names the other door, so the word alone says where it goes.
    public static let exportButtonTitle = "Export"
    public static let exportButtonHint = "Takes these Margins out as a file for yourself, instead of sending them to a friend"
    /// The Export screen's button to Share Margins.
    public static let shareButtonTitle = "Share"
    public static let shareButtonHint = "Sends your Margins here to a friend, instead of exporting a file"
    /// The Export screen's line under its title.
    public static let exportScreenIntro =
        "Take a session out for yourself or your tools, as Markdown or JSON. To send Margins to a friend, tap Share."

    /// Whether the Share Margins sheet offers Export. A reply sheet ("Share replies with <friend>") is a receipt of what
    /// goes back to that friend, so it stays as it is and offers no Export.
    public static func offersExport(isReplyBack: Bool) -> Bool {
        !isReplyBack
    }

    /// The listening session Export starts on, when the listener came from the Share Margins sheet: the session the
    /// sheet was sharing from, if it is one of the item's own, otherwise the item's newest. Nil when the item has no
    /// session: there is nothing to export, and the sheet's Export is off.
    public static func exportSessionId(sharingSessionId: String?, itemSessionIdsNewestFirst: [String]) -> String? {
        if let sharingSessionId, itemSessionIdsNewestFirst.contains(sharingSessionId) { return sharingSessionId }
        return itemSessionIdsNewestFirst.first
    }
}
