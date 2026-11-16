import Foundation
import SessionKit
import SessionKitFeeds

/// The picture of each Library item, as the Library rows and the Now Playing card read it (#3864).
///
/// What is known lives in `item-artwork.json` (`ItemArtworkStore`, SessionKit). This type loads it off the main
/// thread, asks the followed-source coordinator to bring it up to date, and answers a row's question with a
/// dictionary lookup. It is its own object so `Gate1AppModel` does not grow: a Library row that needs a picture
/// observes this, and nothing else in the model changes when a picture arrives.
@MainActor
final class ItemArtworkModel: ObservableObject {
    static let shared = ItemArtworkModel()

    @Published private(set) var store = ItemArtworkStore()
    private var loadedFile: URL?
    private var refreshing = false

    init() {}

    /// The link to draw for a Library row, or nil for today's icon. Only what the file recorded: no parsing, so a long
    /// Library draws without work on the main thread.
    func url(forItem id: String) -> URL? {
        store.recordedArtworkURL(forItem: id)
    }

    /// Reads the file the first time, off the main thread, so a first draw before it lands shows the icon.
    func loadIfNeeded() async {
        guard loadedFile == nil, let file = Self.defaultFile() else { return }
        loadedFile = file
        let loaded = await Task.detached(priority: .utility) { ItemArtworkStore.load(from: file) }.value
        // A refresh that finished first is newer than the file it began from; keep whichever knows more.
        if store == ItemArtworkStore() { store = loaded }
    }

    /// Brings the file up to date with the Library and the followed feeds (nothing is fetched), then publishes it. One
    /// at a time: a call that arrives during another is dropped, and the next Library change asks again.
    func refresh(using coordinator: FollowedSourceCoordinator?) async {
        await loadIfNeeded()
        guard let coordinator, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let updated = await coordinator.itemArtwork()
        if updated != store { store = updated }
    }

    /// The same Application Support folder the model's `applicationSupportDirectory()` makes.
    private static func defaultFile() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: ItemArtworkStore.fileName)
    }
}
