import Combine
import Foundation
import SessionKit

/// The Quick Access folder the listener picked in Add Source (#981, split slice T8): the saved bookmark, the
/// recent files found in it, the files dismissed from Following, the refresh task, and the Quick Add candidate
/// cache. New files only ever wait on Following for the listener to add them; nothing here imports or queues on its own
/// (#4274). The model keeps forwarders under the old names and relays this object's change notifications to its own, so a
/// view that reads `model.quickAccessFolderName` still updates.
@MainActor
final class QuickAccessFolderState: ObservableObject {
    /// UserDefaults keys. Each is stored data from earlier builds, so none may change.
    static let folderBookmarkKey = "quickAccessFolderBookmark"
    static let folderNameKey = "quickAccessFolderName"
    static let dismissedFilesKey = "dismissedQuickAccessFilesV1"
    /// Added in #3770. What the last successful scan learned about the folder, for Settings and Following to say where files
    /// come from. Each is absent in earlier builds' defaults, which reads as unknown, and an older build ignores them.
    static let folderPathKey = "quickAccessFolderPath"
    static let lastCheckedAtKey = "quickAccessLastCheckedAt"
    static let folderProblemKey = "quickAccessFolderProblem"
    /// Removed with the automatic queueing (#4274, owner decision 2026-11-17). Deleted at every launch, so an older build
    /// reads the switch as off and has no stale baseline. Never reuse these names.
    static let retiredKeys = ["quickFolderFeedsQueueV1", "quickFolderInboxSeenFilesV1", "quickFolderInboxSeenWholeFolderV1", "quickAccessLastImportProblem"]
    /// Added in #4274. Files modified since this can be listed on Following even when they are past the newest eight. An older
    /// build ignores it.
    static let folderChosenAtKey = "quickAccessFolderChosenAt"
    /// What the name reads when no folder is chosen.
    static let noFolderName = "No folder selected"

    /// What the state reaches outside itself for, so a test can pin the order of scoped-access calls and
    /// hold a scan open. The defaults are the app's real behaviour.
    struct Dependencies: Sendable {
        /// Scans the folder off the main actor. Not cancellable by the refresh task: a cancelled refresh still
        /// finishes its scan, and a stale result is dropped by the refresh ID, not by cancellation.
        var scan: @Sendable (URL) async -> QuickAccessFolderScan = { url in
            await Task.detached(priority: .utility) { QuickAccessFolderScanner.scan(url) }.value
        }
        var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var bookmarkCreationOptions: URL.BookmarkCreationOptions = QuickAccessFolderState.platformCreationOptions
        /// Runs off the main actor, inside the refresh's detached task, so it must not touch the state.
        var resolveBookmark: @Sendable (Data) throws -> (url: URL, isStale: Bool) = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: QuickAccessFolderState.platformResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
        var now: @Sendable () -> Date = { Date() }
    }

    /// What resolving the saved bookmark found. Built off the main actor, applied on it.
    enum BookmarkResolution: Sendable {
        /// `refreshedBookmark` is set when the system called the bookmark stale and a new one was made under its own scoped access.
        case resolved(url: URL, refreshedBookmark: Data?)
        case failed(description: String)
    }

    @Published var folderName: String
    @Published var recentFiles: [QuickAccessFile] = [] { didSet { cachedCandidates = nil } }
    /// What Following may list (#4274): the newest few files plus every file past them modified since the folder was chosen
    /// (`QuickFolderListing.pool`), with no relative-time wording yet. The candidates take the first few not dismissed. Not
    /// published (the refresh also sets `recentFiles`, which is), and settable so a test can set it as it sets `recentFiles`.
    var followingPool: [QuickAccessFile] = [] { didSet { cachedCandidates = nil } }
    @Published var dismissedFileKeys: Set<String> {
        didSet {
            cachedCandidates = nil
            defaults.set(dismissedFileKeys.sorted(), forKey: Self.dismissedFilesKey)
        }
    }
    @Published private(set) var isRefreshing = false

    /// When the listener chose this folder (#4274), or for a folder chosen in an earlier build, the first launch of this one.
    /// Nil with no folder. Choosing the same folder again keeps it.
    private(set) var folderChosenAt: Date? {
        didSet { Self.store(folderChosenAt, forKey: Self.folderChosenAtKey, in: defaults) }
    }

    /// Where the folder is, as the last successful scan saw it (#3770). Nil until one has finished, and in a build that stored none.
    /// Written only by a scan that finishes successfully, so a moved folder gets its new path.
    @Published private(set) var folderPath: String? {
        didSet { Self.store(folderPath, forKey: Self.folderPathKey, in: defaults) }
    }
    /// When a scan last finished successfully; nil before the first. A failed scan leaves it alone.
    @Published private(set) var lastCheckedAt: Date? {
        didSet { Self.store(lastCheckedAt, forKey: Self.lastCheckedAtKey, in: defaults) }
    }
    /// "Can't open this folder": the bookmark didn't resolve or the folder couldn't be listed. A successful scan clears it.
    @Published private(set) var problem: QuickFolderStatus.Problem? {
        didSet { Self.store(problem?.rawValue, forKey: Self.folderProblemKey, in: defaults) }
    }

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
        Self.retiredKeys.forEach(defaults.removeObject(forKey:))
        folderName = defaults.string(forKey: Self.folderNameKey) ?? Self.noFolderName
        folderPath = defaults.string(forKey: Self.folderPathKey)
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        problem = defaults.string(forKey: Self.folderProblemKey).flatMap(QuickFolderStatus.Problem.init(rawValue:))
        dismissedFileKeys = Set(defaults.stringArray(forKey: Self.dismissedFilesKey) ?? [])
        folderChosenAt = defaults.object(forKey: Self.folderChosenAtKey) as? Date
        if folderChosenAt == nil, defaults.data(forKey: Self.folderBookmarkKey) != nil {
            // An upgrade: files saved from now on can't be stranded past the newest eight; older ones show as before. Set in
            // `init`, so `didSet` doesn't run: store it here.
            let now = dependencies.now()
            folderChosenAt = now
            defaults.set(now, forKey: Self.folderChosenAtKey)
        }
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
            folderFiles: QuickFolderListing.listed(followingPool, dismissedKeys: dismissedFileKeys).map(Self.described),
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems,
            dismissedFileKeys: dismissedFileKeys
        )
        cachedCandidates = candidates
        return candidates
    }

    func invalidateCandidates() { cachedCandidates = nil }

    /// The same short relative-time wording the refresh gives `recentFiles`. Used for at most eight listed files per rebuild.
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func described(_ file: QuickAccessFile) -> QuickAccessFile {
        QuickAccessFile(
            id: file.id,
            name: file.name,
            relativePath: file.relativePath,
            modifiedAt: file.modifiedAt,
            modifiedAtDescription: relativeDateFormatter.localizedString(for: file.modifiedAt, relativeTo: Date())
        )
    }

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
    /// throws and leaves the saved folder alone. What the last scan learned about the old folder (path, last checked,
    /// problem) is dropped; the dismissed set stays.
    func configure(url: URL, whenSaved: () -> Void) throws {
        try save(url: url, keepingWhatAScanLearned: false, whenSaved: whenSaved)
    }

    /// "Choose Folder Again" (#3770). The same folder as the one a scan last saw keeps the last scan's path, last-checked time
    /// and problem (a scan then clears the problem); anything else, or an unknown stored path, drops them, as `configure` does.
    /// The dismissed set stays either way. Returns what it decided.
    @discardableResult
    func reconnect(url: URL, whenSaved: () -> Void) throws -> QuickFolderReconnectRule.Decision {
        let decision = QuickFolderReconnectRule.decide(storedPath: folderPath, chosenPath: url.path)
        try save(url: url, keepingWhatAScanLearned: decision == .keepSeenFiles, whenSaved: whenSaved)
        return decision
    }

    /// "Remove Folder" (#3770). Forgets the folder and everything learned about it. Nothing already imported is touched, and the
    /// dismissed set stays, so the same files don't come back if the folder is chosen again.
    func remove() {
        defaults.removeObject(forKey: Self.folderBookmarkKey)
        defaults.removeObject(forKey: Self.folderNameKey)
        folderName = Self.noFolderName
        folderPath = nil
        lastCheckedAt = nil
        problem = nil
        folderChosenAt = nil
        refresh() // no bookmark: cancels a scan in flight and clears the files
    }

    private func save(url: URL, keepingWhatAScanLearned: Bool, whenSaved: () -> Void) throws {
        // Decided before the branch below clears the stored path. The same folder chosen again, through Choose Folder or Choose
        // Folder Again, keeps its date (#4274); a different one starts its own.
        let isSameFolder = QuickFolderReconnectRule.decide(storedPath: folderPath, chosenPath: url.path) == .keepSeenFiles
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
        if !isSameFolder || folderChosenAt == nil {
            folderChosenAt = dependencies.now()
        }
        if !keepingWhatAScanLearned {
            folderPath = nil
            lastCheckedAt = nil
            problem = nil
        }
        refresh()
        whenSaved()
    }

    /// The saved folder, or nil when none is saved or the bookmark no longer resolves. A stale bookmark is
    /// refreshed in place under its own balanced scoped access. This runs on the calling actor; the refresh does its own
    /// resolving off the main actor, and only an import the listener asked for calls this, once.
    func resolvedFolderURL() -> URL? {
        guard let data = defaults.data(forKey: Self.folderBookmarkKey) else { return nil }
        switch Self.resolve(data, using: dependencies) {
        case let .resolved(url, refreshedBookmark):
            if let refreshedBookmark { defaults.set(refreshedBookmark, forKey: Self.folderBookmarkKey) }
            return url
        case let .failed(description):
            recordDiagnostic("quickAccessBookmarkError", description)
            return nil
        }
    }

    /// Resolves `data`, refreshing a stale bookmark under its own balanced scoped access. Touches no state, so it can run off the
    /// main actor.
    nonisolated static func resolve(_ data: Data, using dependencies: Dependencies) -> BookmarkResolution {
        do {
            let resolved = try dependencies.resolveBookmark(data)
            let url = resolved.url
            guard resolved.isStale else { return .resolved(url: url, refreshedBookmark: nil) }
            let didAccess = dependencies.startAccess(url)
            defer {
                if didAccess {
                    dependencies.stopAccess(url)
                }
            }
            let refreshed = try url.bookmarkData(options: dependencies.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            return .resolved(url: url, refreshedBookmark: refreshed)
        } catch {
            return .failed(description: SafeErrorText.describe(error))
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
    /// or after the folder was cleared, is dropped and leaves the spinner and files to the newer refresh. The bookmark is
    /// resolved in the task, off the main actor (#3770), so a slow provider folder never holds the screen.
    func refresh() {
        guard let bookmark = defaults.data(forKey: Self.folderBookmarkKey) else {
            refreshID = UUID()
            refreshTask?.cancel()
            refreshTask = nil
            isRefreshing = false
            recentFiles = []
            followingPool = []
            return
        }
        let id = UUID()
        refreshID = id
        refreshTask?.cancel()
        isRefreshing = true
        let dependencies = self.dependencies
        refreshTask = Task { [weak self] in
            let resolution = await Task.detached(priority: .utility) { Self.resolve(bookmark, using: dependencies) }.value
            // The task never holds its owner across the scan below: it asks the state for the folder and lets go.
            guard let folderURL = self?.folderToScan(for: resolution, refreshID: id) else { return }
            let didAccess = dependencies.startAccess(folderURL)
            let scan = await dependencies.scan(folderURL)
            if didAccess {
                dependencies.stopAccess(folderURL)
            }
            guard let self, self.refreshID == id else { return }
            self.finishRefresh(scan, folderURL: folderURL)
        }
    }

    /// The folder to scan, or nil when this refresh is stale or the bookmark didn't resolve. An unresolved bookmark ends the
    /// refresh here: the files are cleared and the folder is marked "can't open".
    private func folderToScan(for resolution: BookmarkResolution, refreshID id: UUID) -> URL? {
        guard refreshID == id else { return nil }
        switch resolution {
        case let .resolved(url, refreshedBookmark):
            if let refreshedBookmark { defaults.set(refreshedBookmark, forKey: Self.folderBookmarkKey) }
            return url
        case let .failed(description):
            refreshTask = nil
            isRefreshing = false
            recentFiles = []
            followingPool = []
            problem = .cantOpen
            recordDiagnostic("quickAccessBookmarkError", description)
            return nil
        }
    }

    private func finishRefresh(_ scan: QuickAccessFolderScan, folderURL: URL) {
        refreshTask = nil
        isRefreshing = false
        if let errorDescription = scan.errorDescription {
            recentFiles = []
            followingPool = []
            problem = .cantOpen
            recordDiagnostic("quickAccessError", errorDescription)
            return
        }
        func file(_ entry: QuickAccessFileCandidate, described: Bool = true) -> QuickAccessFile {
            QuickAccessFile(
                id: entry.id,
                name: entry.name,
                relativePath: entry.relativePath,
                modifiedAt: entry.modifiedAt,
                modifiedAtDescription: described ? Self.relativeDateFormatter.localizedString(for: entry.modifiedAt, relativeTo: Date()) : ""
            )
        }
        // Following's pool carries no relative-time wording: a big folder costs no formatting on the main actor, and the
        // candidates word only the few they list.
        followingPool = QuickFolderListing.pool(newest: scan.files, all: scan.allFiles, since: folderChosenAt).map { file($0, described: false) }
        recentFiles = scan.files.map { file($0) }
        folderName = folderURL.lastPathComponent
        // A scan that finished is the only thing that learns where the folder is and when it was checked, and it ends "can't open".
        folderPath = folderURL.path
        lastCheckedAt = dependencies.now()
        problem = nil
        recordDiagnostic("quickAccessFolder", folderURL.lastPathComponent)
        recordDiagnostic("quickAccessRecentFiles", "\(recentFiles.count)")
    }

    /// Writes `value` under `key`, or removes the key for nil.
    private static func store(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
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
