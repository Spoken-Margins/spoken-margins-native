import MediaPlayer
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import UIKit

/// Puts the playing item's picture on the Lock Screen and Control Center card (#3864).
///
/// The card is written by `NowPlayingInfoOwnership` (the ledger), which holds one picture for one item and adds it to every
/// card it publishes for that item. This type finds the playing item's picture link, loads it, and hands it to the ledger.
/// It never writes the card's other keys, and it never shows one item's picture for another: the ledger drops a picture
/// whose item is not the card's, and this type removes the previous item's the moment the item changes.
///
/// An item with no picture, or one that can't be loaded, leaves the card as it was before this existed.
@MainActor
final class NowPlayingArtworkFeeder {
    static let shared = NowPlayingArtworkFeeder()

    private var currentItemId: String?
    private var task: Task<Void, Never>?
    private let ledger: NowPlayingInfoOwnership
    private let artwork: ItemArtworkModel
    private let loader: ArtworkThumbnailLoader

    init(
        ledger: NowPlayingInfoOwnership = .shared,
        artwork: ItemArtworkModel = .shared,
        loader: ArtworkThumbnailLoader = .shared
    ) {
        self.ledger = ledger
        self.artwork = artwork
        self.loader = loader
    }

    /// The item that is playing changed; nil when none is. Called from the snapshot's change handler, so it does nothing
    /// unless the item differs.
    func playingItemChanged(_ itemId: String?, coordinator: FollowedSourceCoordinator?) {
        guard itemId != currentItemId else { return }
        let previous = currentItemId
        currentItemId = itemId
        task?.cancel()
        task = nil
        if let previous { ledger.setArtwork(nil, forItem: previous) }
        guard let itemId else { return }
        task = Task { [weak self] in
            await self?.feed(itemId: itemId, coordinator: coordinator)
        }
    }

    private func feed(itemId: String, coordinator: FollowedSourceCoordinator?) async {
        await artwork.loadIfNeeded()
        var url = artwork.url(forItem: itemId)
        if url == nil {
            // The Library screen may not have been open since the item was added: bring the record up to date once.
            await artwork.refresh(using: coordinator)
            url = artwork.url(forItem: itemId)
        }
        guard let url, !Task.isCancelled, currentItemId == itemId else { return }
        guard let image = await loader.thumbnail(for: url, maxPixelSize: ArtworkThumbnailLoader.nowPlayingPixelSize),
              !Task.isCancelled, currentItemId == itemId else { return }
        ledger.setArtwork(Self.makeArtwork(image), forItem: itemId)
    }

    /// Built outside the main actor's isolation: the system calls the image handler on its own queue, and a closure made
    /// inside a main-actor method would assert that it runs on main.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
