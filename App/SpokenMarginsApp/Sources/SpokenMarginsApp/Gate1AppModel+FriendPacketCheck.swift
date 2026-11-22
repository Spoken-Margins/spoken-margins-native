import Foundation
import SessionKit

extension Gate1AppModel {
    /// Whether the Library holds a friend's packet that isn't deleted, for the first-launch "Got a link from a friend?"
    /// card (#3782). The read runs off the main thread; with no store open the answer is yes, so the card stays hidden
    /// rather than offering a paste to a Library that can't take one. The rule is `FirstLaunchFriendLinkCard`'s.
    func libraryHoldsFriendPacket() async -> Bool {
        guard let store else { return true }
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let layers = try? store.loadImportedCommentaryLayers() else { return true }
            return FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: layers)
        }.value
    }
}
