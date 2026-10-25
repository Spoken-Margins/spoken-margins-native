import Combine
import Foundation
import SessionKit

/// The Quick Access folder the listener picked in Add Source (#981, split slice T8): the saved bookmark, the
/// recent files found in it, the files dismissed from Following, the refresh task, and the Quick Add candidate
/// cache. It moved out of `Gate1AppModel` unchanged; the model keeps forwarders under the old names and
/// relays this object's change notifications to its own, so a view that reads `model.quickAccessFolderName`
/// still updates.
@MainActor
final class QuickAccessFolderState: ObservableObject {
    /// UserDefaults keys. Each is stored data from earlier builds, so none may change.
    static let folderBookmarkKey = "quickAccessFolderBookmark"
    static let folderNameKey = "quickAccessFolderName"
    static let dismissedFilesKey = "dismissedQuickAccessFilesV1"
    /// Added in #1990 slice 3. Absent in earlier builds' defaults, which reads as off and no baseline.
    static let inboxFeedsQueueKey = "quickFolderFeedsQueueV1"
    static let inboxSeenFilesKey = "quickFolderInboxSeenFilesV1"

    /// What the state reaches outside itself for, so a test can pin the order of scoped-access calls and
    /// hold a scan open. The defaults are the app's real behaviour.
    struct Dependencies {
        /// Scans the folder off the main actor. Not cancellable by the refresh task: a cancelled refresh still
        /// finishes its scan, and a stale result is dropped by the refresh ID, not by cancellation.
        var scan: @Sendable (URL) async -> QuickAccessFolderScan = { url in
            await Task.detached(priority: .utility) { QuickAccessFolderScanner.scan(url) }.value
        }
        var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var bookmarkCreationOptions: URL.BookmarkCreationOptions = QuickAccessFolderState.platformCreationOptions
        var resolveBookmark: (Data) throws -> (url: URL, isStale: Bool) = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: QuickAccessFolderState.platformResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    }

    @Published var folderName: String
    @Published var recentFiles: [QuickAccessFile] = [] { didSet { cachedCandidates = nil } }
    @Published var dismissedFileKeys: Set<String> {
        didSet {
            cachedCandidates = nil
            defaults.set(dismissedFileKeys.sorted(), forKey: Self.dismissedFilesKey)
        }
    }
    @Published private(set) var isRefreshing = false

    /// Opt-in (#1990): files that newly appear in the folder are imported and appended to the play queue.
    @Published var inboxFeedsQueue: Bool {
        didSet {
            defaults.set(inboxFeedsQueue, forKey: Self.inboxFeedsQueueKey)
            // Turning it on starts from the files already there; they are not swept into the queue.
            if inboxFeedsQueue != oldValue { inboxSeenFileIds = nil }
            if inboxFeedsQueue { refresh() }
        }
    }

    /// Ids of folder files the inbox has already taken in. Nil until a baseline is taken for this folder.
    var inboxSeenFileIds: Set<String>? {
        get { defaults.object(forKey: Self.inboxSeenFilesKey) == nil ? nil : Set(defaults.stringArray(forKey: Self.inboxSeenFilesKey) ?? []) }
        set {
            if let newValue { defaults.set(newValue.sorted(), forKey: Self.inboxSeenFilesKey) } else { defaults.removeObject(forKey: Self.inboxSeenFilesKey) }
        }
    }

    /// Runs after a refresh stored the folder's files. The model installs it.
    var onFilesRefreshed: () -> Void = {}

    /// Writes a diagnostics value. The model installs this; it is not a published field, so a diagnostics
    /// write never invalidates a view that watches this state.
    var recordDiagnostic: (String, String) -> Void = { _, _ in }

    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var cachedCandidates: [QuickAddCandidate]?
    private var willChangeRelay: AnyCancellable?

    init(defaults: UserDefaults = .standard, dependencies: Dependencies = Dependencies()) {
        self.defaults = defaults
        self.dependencies = dependencies
        folderName = defaults.string(forKey: Self.folderNameKey) ?? "No folder selected"
        dismissedFileKeys = Set(defaults.stringArray(forKey: Self.dismissedFilesKey) ?? [])
        inboxFeedsQueue = defaults.bool(forKey: Self.inboxFeedsQueueKey)
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Sends `target` a change notification whenever this state is about to change, in the same turn, so the
    /// model's views invalidate exactly as they did when these fields were the model's own.
    func forwardWillChange(to target: ObservableObjectPublisher) {
        willChangeRelay = objectWillChange.sink { _ in target.send() }
    }

    // MARK: Quick Add candidates

    /// The Quick Add list: this folder's files plus the followed-source entries, minus what is imported or
    /// dismissed. Cached until any input changes: this state's own files and dismissed keys invalidate it
    /// here, and the model calls `invalidateCandidates()` when its Library, followed entries or
    /// subscriptions change.
    func candidates(
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription],
        libraryItems: [LibraryItemRow]
    ) -> [QuickAddCandidate] {
        if let cachedCandidates { return cachedCandidates }
        let candidates = Self.candidates(
            folderFiles: recentFiles,
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems,
            dismissedFileKeys: dismissedFileKeys
        )
        cachedCandidates = candidates
        return candidates
    }

    func invalidateCandidates() { cachedCandidates = nil }

    nonisolated static func candidates(
        folderFiles: [QuickAccessFile],
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription] = [],
        libraryItems: [LibraryItemRow] = [],
        dismissedFileKeys: Set<String> = []
    ) -> [QuickAddCandidate] {
        QuickAddFeed.candidates(
            folderFiles: folderFiles,
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems.map {
                QuickAddImportedItem(sourceReference: $0.sourceReference, title: $0.title, sourceTitle: $0.sourceTitle)
            },
            dismissedFileKeys: dismissedFileKeys
        )
    }

    func dismiss(_ file: QuickAccessFile) { dismissedFileKeys.insert(file.dismissalKey) }

    /// Brings a dismissed Quick Folder file back into Following (#477).
    func restore(_ file: QuickAccessFile) { dismissedFileKeys.remove(file.dismissalKey) }

    // MARK: Folder bookmark

    /// Saves `url` as the Quick Folder and starts a refresh. `whenSaved` runs after the refresh starts and
    /// while scoped access to `url` is still held, as the model's success message did. A bookmark failure
    /// throws and leaves the saved folder alone.
    func configure(url: URL, whenSaved: () -> Void) throws {
        let didAccess = dependencies.startAccess(url)
        defer {
            if didAccess {
                dependencies.stopAccess(url)
            }
        }
        let bookmark = try url.bookmarkData(options: dependencies.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.folderBookmarkKey)
        defaults.set(url.lastPathComponent, forKey: Self.folderNameKey)
        folderName = url.lastPathComponent
        inboxSeenFileIds = nil // a different folder: files already in it are not new
        refresh()
        whenSaved()
    }

    /// The saved folder, or nil when none is saved or the bookmark no longer resolves. A stale bookmark is
    /// refreshed in place under its own balanced scoped access.
    func resolvedFolderURL() -> URL? {
        guard let data = defaults.data(forKey: Self.folderBookmarkKey) else { return nil }
        do {
            let resolved = try dependencies.resolveBookmark(data)
            let url = resolved.url
            if resolved.isStale {
                let didAccess = dependencies.startAccess(url)
                defer {
                    if didAccess {
                        dependencies.stopAccess(url)
                    }
                }
                let refreshed = try url.bookmarkData(options: dependencies.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(refreshed, forKey: Self.folderBookmarkKey)
            }
            return url
        } catch {
            recordDiagnostic("quickAccessBookmarkError", String(describing: error))
            return nil
        }
    }

    /// The URLs an import of `file` needs: the file inside the saved folder, and the folder, whose scoped
    /// access the import holds while it reads. Nil when no folder is saved.
    func importURLs(for file: QuickAccessFile) -> (fileURL: URL, folderURL: URL)? {
        guard let folderURL = resolvedFolderURL() else { return nil }
        return (folderURL.appending(path: file.relativePath), folderURL)
    }

    // MARK: Refresh

    /// Rescans the saved folder. The newest refresh wins: a scan that finishes after a newer refresh started,
    /// or after the folder was cleared, is dropped and leaves the spinner and files to the newer refresh.
    func refresh() {
        guard let folderURL = resolvedFolderURL() else {
            refreshID = UUID()
            refreshTask?.cancel()
            refreshTask = nil
            isRefreshing = false
            recentFiles = []
            return
        }
        let id = UUID()
        refreshID = id
        refreshTask?.cancel()
        let didAccess = dependencies.startAccess(folderURL)
        isRefreshing = true
        let scanFolder = dependencies.scan
        let stopAccess = dependencies.stopAccess
        refreshTask = Task { [weak self] in
            let scan = await scanFolder(folderURL)
            if didAccess {
                stopAccess(folderURL)
            }
            guard let self, self.refreshID == id else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            if let errorDescription = scan.errorDescription {
                self.recentFiles = []
                self.recordDiagnostic("quickAccessError", errorDescription)
                return
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            self.recentFiles = scan.files.map { entry in
                QuickAccessFile(
                    id: entry.id,
                    name: entry.name,
                    relativePath: entry.relativePath,
                    modifiedAt: entry.modifiedAt,
                    modifiedAtDescription: formatter.localizedString(for: entry.modifiedAt, relativeTo: Date())
                )
            }
            self.folderName = folderURL.lastPathComponent
            self.recordDiagnostic("quickAccessFolder", folderURL.lastPathComponent)
            self.recordDiagnostic("quickAccessRecentFiles", "\(self.recentFiles.count)")
            self.onFilesRefreshed()
        }
    }

    // MARK: Platform bookmark options

    nonisolated static var platformCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    nonisolated static var platformResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
}
