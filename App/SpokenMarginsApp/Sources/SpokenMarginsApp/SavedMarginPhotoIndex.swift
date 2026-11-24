import Foundation
import SessionKit
import SwiftUI

/// The app's one lookup of saved live-session photos, keyed by the saved Margin's id (#4180). It is read off the main
/// thread once per launch (`load(from:)`), then kept current in place: `add` when a session is saved, `remove` when its
/// item is purged. Screens that draw the listener's own Margins observe it directly (not through a feed's `Inputs`):
/// it publishes about once per launch plus once per save or purge, and an observed object redraws its own view through
/// any `.equatable()` parent.
///
/// Before the launch load finishes, every lookup is nil, so a row has no photo slot and the Margin screen shows neither
/// a photo nor the missing-file line; there is never a wrong first state, only a photo that appears.
@MainActor
final class SavedMarginPhotoIndex: ObservableObject {
    static let shared = SavedMarginPhotoIndex()

    @Published private(set) var photos = SavedMarginPhotos(records: [])
    @Published private(set) var isLoaded = false
    /// Items saved or purged since the current launch load began; the load's result never overwrites them.
    private var touchedItemIds: Set<String> = []

    init() {}

    func photo(forMarginId id: String) -> SavedMarginPhoto? {
        photos.photo(forMarginId: id)
    }

    /// A session was saved and its record written: its photos show on the item's first draw, with no file read.
    func add(_ record: LiveSessionRecord) {
        photos.add(record)
        touchedItemIds.insert(record.itemId)
    }

    /// The item was purged: nothing shows a photo for it again.
    func remove(itemId: String) {
        photos.remove(itemId: itemId)
        touchedItemIds.insert(itemId)
    }

    /// Reads every session record in `directory` off the main thread and merges the result, keeping any save or purge
    /// that landed while it read.
    func load(from directory: URL?) {
        touchedItemIds = []
        guard let directory else {
            isLoaded = true
            return
        }
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { SavedMarginPhotos.load(from: directory) }.value
            guard let self else { return }
            photos = photos.merging(loaded: loaded, touchedItemIds: touchedItemIds)
            isLoaded = true
        }
    }
}

/// The 48 pt thumbnail for one of the listener's own rows on the dark listening surface (Now Playing's Margins pane and
/// Nearby Margins), as the live session's pane draws it (#4180). Looked up by the Margin's own id: `MarginRow.id` is the
/// composite "session::margin" id and is not the key.
@MainActor
func photoThumbnail(_ index: SavedMarginPhotoIndex, for row: MarginRow) -> AnyView? {
    index.photo(forMarginId: row.interjection.id).map { AnyView(LiveSessionPhotoThumbnail(source: .kept($0.photo))) }
}
