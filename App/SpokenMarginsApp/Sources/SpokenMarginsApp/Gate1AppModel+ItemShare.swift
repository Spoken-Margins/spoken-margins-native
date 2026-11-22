import Foundation
import SessionKit

/// The item screen's Share (#4229). It opens the friend sheet the player opens, started on the open item, so the two
/// doors cannot decide differently. The words and the rule are in SessionKit (`ItemShareStart`); this adds no stored state.
extension Gate1AppModel {
    /// Whether the open item has Margins of the listener's own to send. The rows lag a Margin saved or a packet imported a
    /// moment ago, so a first "nothing" is re-read off the main thread before it is believed.
    func itemShareStart() async -> ItemShareStart {
        if case .nothingYet = decideItemShare() { await refreshMarginRowsAsync(forItem: selectedItem.id) }
        return decideItemShare()
    }

    /// Opens the player's Share for the open item. A second tap while the sheet is up keeps the listener's choices. The caller
    /// labels it for the hang probe, because its store reads run on the caller's task.
    func openItemShareSheet() {
        guard !isSharingInterjectionsPresented else { return }
        openPlaybackShareStartingWithFriendAnswers()
    }

    private func decideItemShare() -> ItemShareStart {
        let facts = friendItemFacts
        return ItemShareStart.start(ownMargins: facts.localMargins, hasFriendMargins: !facts.layers.isEmpty)
    }
}
