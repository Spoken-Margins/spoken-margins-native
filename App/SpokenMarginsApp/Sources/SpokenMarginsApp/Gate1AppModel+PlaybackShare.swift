import Foundation
import SessionKit

extension Gate1AppModel {
    /// Share on the playback screen (#1507): the Share Margins sheet for this item opens on its review, with the
    /// default Margins selected and Share pinned at the bottom. Share, then Share again, is two taps to the iOS
    /// share sheet. The player keeps playing under the sheet. The long Export screen is for a session export and
    /// stays under More.
    func openPlaybackShare() {
        openMarginItemExport(itemID: selectedItem.id, entry: .reviewDefaults)
    }
}
