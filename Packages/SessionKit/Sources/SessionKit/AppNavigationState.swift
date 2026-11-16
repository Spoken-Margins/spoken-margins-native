import Foundation

public enum AppRoot: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library
    case sources
    case margins
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .library: "Library"
        case .sources: "Following"
        case .margins: "Margins"
        case .settings: "Settings"
        }
    }

    /// What the Item screen's back button says: the tab it returns to (#3214). Settings has no items, so it
    /// reads just "Back".
    public var itemBackTitle: String {
        switch self {
        case .library, .sources, .margins: title
        case .settings: "Back"
        }
    }

    public var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .sources: "dot.radiowaves.left.and.right"
        case .margins: "quote.bubble"
        case .settings: "gearshape"
        }
    }
}

public enum AppRoute: Hashable, Sendable {
    case item(String)
    case nowPlaying
    case timeline(String?)
    case marginDetail(String)
    case settings
    case offlineStorage
    case export(String?)
    case batchExport
    case help
}

public enum AddSourceRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case linkOrPodcast
    case pastedText
    /// One tile for everything that comes from Files: documents, books, audiobooks and `.spokenmargins` packets.
    /// The file's own type picks the import after the pick (`AddFromFilesPlan`, #3217).
    case importFromFiles
    case quickFolder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .linkOrPodcast: "Link or Podcast"
        case .pastedText: "Paste Text"
        case .importFromFiles: "Import from Files"
        case .quickFolder: "Quick Folder"
        }
    }

    public var detail: String {
        switch self {
        case .linkOrPodcast: "Podcast episode, RSS feed, public audio, or readable web link"
        case .pastedText: "Make something to listen to from text already on your clipboard"
        case .importFromFiles: "A document, book, transcript, audiobook or Margins packet from Files"
        case .quickFolder: "Choose a folder whose eligible files appear in Following"
        }
    }

    public var systemImage: String {
        switch self {
        case .linkOrPodcast: "link"
        case .pastedText: "text.quote"
        case .importFromFiles: "folder.badge.plus"
        case .quickFolder: "folder"
        }
    }
}

/// Scene-local presentation state. Playback and persistence remain in
/// `Gate1AppModel`; switching roots must not replace an active session.
public struct AppNavigationState: Equatable, Sendable {
    public var selectedRoot: AppRoot = .library
    public var paths: [AppRoot: [AppRoute]] = [
        .library: [],
        .sources: [],
        .margins: [],
        .settings: []
    ]
    public var taskRoute: AppRoute?
    public var addSourceRoute: AddSourceRoute?
    /// "Search podcasts by name" in the add sheet: the sheet closes first, then the catalog opens (#1784).
    public var opensCatalogAfterAddSheet = false
    /// Where Following was scrolled to, kept across the screen switches that destroy its list (#479).
    public var followingScroll = FollowingScrollMemory()
    /// The same for the Library list, whose rows are also destroyed when an item opens (#2395).
    public var libraryScroll = FollowingScrollMemory()

    /// Where the listener is, without the scroll memory: scrolling the list while a tapped item is read keeps the
    /// tap; a change of place drops it (#2505).
    public struct Place: Equatable {
        public let root: AppRoot
        public let paths: [AppRoot: [AppRoute]]
        public let taskRoute: AppRoute?
        public let addSourceRoute: AddSourceRoute?
    }

    public init() {}

    public var place: Place {
        Place(root: selectedRoot, paths: paths, taskRoute: taskRoute, addSourceRoute: addSourceRoute)
    }

    public mutating func select(_ root: AppRoot, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        selectedRoot = root
    }

    public mutating func push(_ route: AppRoute, in root: AppRoot? = nil, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        let destination = root ?? selectedRoot
        paths[destination, default: []].append(route)
    }

    public mutating func present(_ route: AppRoute, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        taskRoute = route
    }

    public mutating func searchPodcastsFromAddSheet() {
        addSourceRoute = nil
        opensCatalogAfterAddSheet = true
    }

    /// True once per request, so a later dismissal of the sheet doesn't open the catalog again.
    public mutating func takeCatalogRequest() -> Bool {
        defer { opensCatalogAfterAddSheet = false }
        return opensCatalogAfterAddSheet
    }

    public mutating func dismissTask(recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        taskRoute = nil
    }
}
