import Foundation
import SessionKit

/// One tap between the Share Margins sheet and the Export screen, for the same item (#5306). The rules and words are in
/// SessionKit (`ShareExportSwitch`); this adds no stored state. Neither door sends, builds or writes anything by itself.
extension Gate1AppModel {
    /// The session Export should start on when the listener leaves the Share Margins sheet for it. Read before the sheet
    /// closes, while `exportSessionId` still names the session the sheet was sharing from. Nil: nothing to export.
    func exportSessionForShareSwitch() -> String? {
        ShareExportSwitch.exportSessionId(
            sharingSessionId: exportSessionId,
            itemSessionIdsNewestFirst: selectedItem.sessions.map(\.id))
    }

    /// The Share Margins sheet's Export, after the sheet has been closed: the Export screen on the same item.
    func openExportFromShareSheet(sessionId: String) {
        openExport(sessionId: sessionId)
    }
}
