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
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init() {}

    /// The link to draw for a Library row, or nil for today's icon. Only what the file recorded: no parsing, so a long
    /// Library draws without work on the main thread.
    func url(forItem id: String) -> URL? {
        store.recordedArtworkURL(forItem: id)
    }

    /// Reads the file the first time, off the main thread, so a first draw before it lands shows the icon. A second
    /// caller waits for the first read instead of returning at once, so nobody reads an empty store while it loads.
    func loadIfNeeded() async {
        if loadTask == nil, let file = Self.defaultFile() {
            loadTask = Task { [weak self] in
                let loaded = await Task.detached(priority: .utility) { ItemArtworkStore.load(from: file) }.value
                // Keep whatever a refresh has already published; the file is only the starting point.
                if let self, self.store == ItemArtworkStore() { self.store = loaded }
            }
        }
        await loadTask?.value
    }

    /// Brings the file up to date with the Library and the followed feeds (nothing is fetched), then publishes it. Calls
    /// run one after another, never dropped: a call that arrives during another waits for it, then runs itself, so the
    /// Library change or the playing item that asked is covered by a read that began after it.
    func refresh(using coordinator: FollowedSourceCoordinator?) async {
        await loadIfNeeded()
        guard let coordinator else { return }
        while let running = refreshTask { await running.value }
        let task = Task { [weak self] in
            let updated = await coordinator.itemArtwork()
            if let self {
                if updated != self.store { self.store = updated }
                self.refreshTask = nil
            }
        }
        refreshTask = task
        await task.value
    }

    /// The same Application Support folder the model's `applicationSupportDirectory()` makes.
    private static func defaultFile() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: ItemArtworkStore.fileName)
    }
}
