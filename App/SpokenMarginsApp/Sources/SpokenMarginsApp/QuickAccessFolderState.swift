import Combine
import Foundation
import SessionKit

/// The listener's Quick Folders (#981, split slice T8; more than one since #3770 Design PR 4 and 5): the saved folders, the
/// recent files found in each, the files dismissed from Following, the refresh tasks, and the Quick Add candidate cache. New
/// files only ever wait on Following for the listener to add them; nothing here imports or queues on its own (#4274). The model
/// keeps forwarders under the old names and relays this object's change notifications to its own, so a view that reads
/// `model.quickAccessFolderName` still updates.
///
/// The folders are a `QuickFolderList` (SessionKit), saved under `quickFoldersV2`; entry 1 keeps writing the single keys the one
/// Quick Folder used before, so an older build still finds it (`QuickFolderListStore`). The properties without a folder id
/// (`folderName`, `recentFiles`, `configure`, `remove()`, ...) are entry 1's, as they were the one folder's; the ones with an
/// id are each folder's own. A file listed on Following carries an id unique across folders (`QuickFolderList.qualified`).
@MainActor
final class QuickAccessFolderState: ObservableObject {
    /// UserDefaults keys. Each is stored data from earlier builds, so none may change.
    static let folderBookmarkKey = QuickFolderList.LegacyKeys.bookmarkKey
    static let folderNameKey = QuickFolderList.LegacyKeys.nameKey
    static let dismissedFilesKey = QuickFolderList.LegacyKeys.dismissedKey
    /// Added in #3770. What the last successful scan learned about the folder, for Settings and Following to say where files
    /// come from. Each is absent in earlier builds' defaults, which reads as unknown, and an older build ignores them.
    static let folderPathKey = QuickFolderList.LegacyKeys.pathKey
    static let lastCheckedAtKey = QuickFolderList.LegacyKeys.lastCheckedAtKey
    static let folderProblemKey = QuickFolderList.LegacyKeys.problemKey
    /// Removed with the automatic queueing (#4274, owner decision 2026-11-17). Deleted at every launch, so an older build
    /// reads the switch as off and has no stale baseline. Never reuse these names.
    static let retiredKeys = ["quickFolderFeedsQueueV1", "quickFolderInboxSeenFilesV1", "quickFolderInboxSeenWholeFolderV1", "quickAccessLastImportProblem"]
    /// Added in #4274. Files modified since this can be listed on Following even when they are past the newest eight. An older
    /// build ignores it.
    static let folderChosenAtKey = QuickFolderList.LegacyKeys.chosenAtKey
    /// What the name reads when no folder is chosen.
    static let noFolderName = "No folder selected"
    /// Where files set on this state with no folder chosen are kept (a test sets them so). Never a folder id: those are UUIDs.
    private static let noFolderKey = ""

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
        /// A new folder's id in the list. Never reused.
        var newID: @Sendable () -> String = { UUID().uuidString }
    }

    /// What resolving the saved bookmark found. Built off the main actor, applied on it.
    enum BookmarkResolution: Sendable {
        /// `refreshedBookmark` is set when the system called the bookmark stale and a new one was made under its own scoped access.
        case resolved(url: URL, refreshedBookmark: Data?)
        case failed(description: String)
    }

    /// What one folder's last scan found, with plain file ids. Not stored: every launch scans again.
    struct FolderFiles: Equatable {
        var recentFiles: [QuickAccessFile] = []
        /// What Following may list (#4274): the newest few files plus every file past them modified since the folder was chosen
        /// (`QuickFolderListing.pool`), with no relative-time wording yet. The candidates take the first few not dismissed.
        var followingPool: [QuickAccessFile] = []
        var isRefreshing = false
    }

    /// The folders, in the order they were added; entry 1 first. Every change is saved at once (`changeList`).
    @Published private(set) var list: QuickFolderList { didSet { cachedCandidates = nil } }
    /// Each folder's files, by folder id.
    @Published private var files: [QuickFolderList.Entry.ID: FolderFiles] = [:] { didSet { cachedCandidates = nil } }
    /// The dismissed files while no folder is chosen: the single key as it stands, kept so the same files stay dismissed.
    @Published private var dismissedWithNoFolder: Set<String> { didSet { cachedCandidates = nil } }
    /// Entry 1's name as shown, or `noFolderName`. Set when a folder is chosen, removed or scanned; settable so a test can set it.
    @Published var folderName: String

    /// Writes a diagnostics value. The model installs this; it is not a published field, so a diagnostics
    /// write never invalidates a view that watches this state.
    var recordDiagnostic: (String, String) -> Void = { _, _ in }

    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var refreshTasks: [QuickFolderList.Entry.ID: Task<Void, Never>] = [:]
    private var refreshIDs: [QuickFolderList.Entry.ID: UUID] = [:]
    /// The path each folder was chosen at in this run, standardized. Change Folder clears a folder's stored path until its next
    /// scan, so the duplicate check reads this too and a folder can't be chosen twice in that gap.
    private var chosenPaths: [QuickFolderList.Entry.ID: String] = [:]
    private var cachedCandidates: [QuickAddCandidate]?
    private var willChangeRelay: AnyCancellable?

    init(defaults: UserDefaults = .standard, dependencies: Dependencies = Dependencies()) {
        self.defaults = defaults
        self.dependencies = dependencies
        Self.retiredKeys.forEach(defaults.removeObject(forKey:))
        let list = Self.loadList(from: defaults, dependencies: dependencies)
        self.list = list
        dismissedWithNoFolder = Set(defaults.stringArray(forKey: Self.dismissedFilesKey) ?? [])
        folderName = Self.shownName(of: list)
    }

    deinit {
        refreshTasks.values.forEach { $0.cancel() }
    }

    /// Sends `target` a change notification whenever this state is about to change, in the same turn, so the
    /// model's views invalidate exactly as they did when these fields were the model's own.
    func forwardWillChange(to target: ObservableObjectPublisher) {
        willChangeRelay = objectWillChange.sink { _ in target.send() }
    }

    // MARK: Entry 1, as the one folder was

    private var primaryKey: QuickFolderList.Entry.ID { list.folders.first?.id ?? Self.noFolderKey }

    /// Entry 1's newest files, for the Add sheet.
    var recentFiles: [QuickAccessFile] {
        get { files[primaryKey]?.recentFiles ?? [] }
        set { files[primaryKey, default: FolderFiles()].recentFiles = newValue }
    }

    /// Entry 1's Following pool (plain ids). Settable so a test can set it as it sets `recentFiles`.
    var followingPool: [QuickAccessFile] {
        get { files[primaryKey]?.followingPool ?? [] }
        set { files[primaryKey, default: FolderFiles()].followingPool = newValue }
    }

    /// Entry 1's dismissed files, or with no folder the ones kept from the last folder (#477).
    var dismissedFileKeys: Set<String> {
        get { list.folders.first?.dismissedKeys ?? dismissedWithNoFolder }
        set {
            if let first = list.folders.first {
                changeList { $0.update(first.id) { $0.dismissedKeys = newValue } }
            } else {
                dismissedWithNoFolder = newValue
                defaults.set(newValue.sorted(), forKey: Self.dismissedFilesKey)
            }
        }
    }

    /// True while any folder is being scanned.
    var isRefreshing: Bool { files.values.contains { $0.isRefreshing } }

    /// When the listener chose entry 1 (#4274), or for a folder chosen in an earlier build, the first launch of this one.
    /// Nil with no folder. Choosing the same folder again keeps it.
    var folderChosenAt: Date? { list.folders.first?.chosenAt }
    /// Where entry 1 is, as its last successful scan saw it (#3770). Nil until one has finished, and in a build that stored none.
    var folderPath: String? { list.folders.first?.path }
    /// When a scan of entry 1 last finished successfully; nil before the first. A failed scan leaves it alone.
    var lastCheckedAt: Date? { list.folders.first?.lastCheckedAt }
    /// "Can't open this folder" for entry 1: the bookmark didn't resolve or the folder couldn't be listed.
    var problem: QuickFolderStatus.Problem? { list.folders.first?.problem }

    // MARK: Each folder

    var folders: [QuickFolderList.Entry] { list.folders }
    var canAddFolder: Bool { !list.isFull }

    /// One folder's newest files for the Add sheet, with ids unique across folders.
    func newestFiles(in folderID: QuickFolderList.Entry.ID) -> [QuickAccessFile] {
        (files[folderID]?.recentFiles ?? []).map { list.qualified($0, in: folderID) }
    }

    func isScanning(_ folderID: QuickFolderList.Entry.ID) -> Bool { files[folderID]?.isRefreshing ?? false }

    /// The folder a listed file (by its id across folders) came from; nil for a folder no longer in the list.
    func folderID(of file: QuickAccessFile) -> QuickFolderList.Entry.ID? { list.folderAndFileID(file.id)?.folderID }

    // MARK: Quick Add candidates

    /// The Quick Add list: every folder's files plus the followed-source entries, minus what is imported or dismissed. Cached
    /// until any input changes: this state's own files, folders and dismissed keys invalidate it here, and the model calls
    /// `invalidateCandidates()` when its Library, followed entries or subscriptions change.
    func candidates(
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription],
        libraryItems: [LibraryItemRow]
    ) -> [QuickAddCandidate] {
        if let cachedCandidates { return cachedCandidates }
        // Each folder's own dismissals are applied here, in its own folder, so no set is passed on.
        let listed = list.folders.isEmpty
            ? QuickFolderListing.listed(files[Self.noFolderKey]?.followingPool ?? [], dismissedKeys: dismissedWithNoFolder)
            : list.listedFiles(pools: files.mapValues(\.followingPool))
        let candidates = Self.candidates(
            folderFiles: listed.map(Self.described),
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems
        )
        cachedCandidates = candidates
        return candidates
    }

    func invalidateCandidates() { cachedCandidates = nil }

    /// The same short relative-time wording the refresh gives `recentFiles`. Used for at most eight listed files per folder per rebuild.
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

    /// Hides a listed file in its own folder. A file whose folder is gone is not dismissed into another one; with no folder at all
    /// it goes in the kept set.
    func dismiss(_ file: QuickAccessFile) {
        if let target = list.dismissal(of: file) {
            changeList { $0.update(target.folderID) { $0.dismissedKeys.insert(target.key) } }
        } else if list.folders.isEmpty {
            dismissedFileKeys.insert(file.dismissalKey)
        }
    }

    /// Brings a dismissed Quick Folder file back into Following (#477).
    func restore(_ file: QuickAccessFile) {
        if let target = list.dismissal(of: file) {
            changeList { $0.update(target.folderID) { $0.dismissedKeys.remove(target.key) } }
        } else if list.folders.isEmpty {
            dismissedFileKeys.remove(file.dismissalKey)
        }
    }

    // MARK: Choosing folders

    /// What choosing a folder can refuse.
    enum ChoiceError: Error, Equatable {
        /// That folder is already one of the Quick Folders.
        case duplicate
        /// `QuickFolderList.limit` folders are chosen already.
        case full

        var message: String {
            switch self {
            case .duplicate: QuickFolderStatus.duplicateFolderMessage
            case .full: QuickFolderStatus.fullMessage
            }
        }
    }

    /// Saves `url` as entry 1 (the first folder when none is chosen) and starts its refresh. `whenSaved` runs after the refresh
    /// starts and while scoped access to `url` is still held, as the model's success message did. A bookmark failure throws and
    /// leaves the saved folders alone, and so does a folder that is already another Quick Folder (`ChoiceError.duplicate`).
    /// What the last scan learned about the old folder (path, last checked, problem) is dropped; the dismissed set stays.
    func configure(url: URL, whenSaved: () -> Void) throws {
        if let first = list.folders.first {
            try configure(url: url, folder: first.id, whenSaved: whenSaved)
        } else {
            try add(url: url, whenSaved: whenSaved)
        }
    }

    /// "Change Folder" for one folder, as `configure` does for entry 1.
    func configure(url: URL, folder folderID: QuickFolderList.Entry.ID, whenSaved: () -> Void) throws {
        try save(url: url, into: folderID, keepingWhatAScanLearned: false, whenSaved: whenSaved)
    }

    /// "Choose Folder Again" (#3770) for entry 1. The same folder as the one a scan last saw keeps the last scan's path,
    /// last-checked time and problem (a scan then clears the problem); anything else, or an unknown stored path, drops them, as
    /// `configure` does. The dismissed set stays either way. Returns what it decided.
    @discardableResult
    func reconnect(url: URL, whenSaved: () -> Void) throws -> QuickFolderReconnectRule.Decision {
        guard let first = list.folders.first else {
            try add(url: url, whenSaved: whenSaved)
            return .freshBaseline
        }
        return try reconnect(url: url, folder: first.id, whenSaved: whenSaved)
    }

    /// "Choose Folder Again" for one folder.
    @discardableResult
    func reconnect(url: URL, folder folderID: QuickFolderList.Entry.ID, whenSaved: () -> Void) throws -> QuickFolderReconnectRule.Decision {
        let decision = QuickFolderReconnectRule.decide(storedPath: list.entry(folderID)?.path, chosenPath: url.path)
        try save(url: url, into: folderID, keepingWhatAScanLearned: decision == .keepSeenFiles, whenSaved: whenSaved)
        return decision
    }

    /// "Add Another Folder" (#3770 Design PR 5): `url` becomes the last folder and is scanned. A folder removed earlier gets its
    /// dismissed files back. Refused, with nothing saved, when it is already a Quick Folder or the list is full; a bookmark
    /// failure throws. `whenSaved` runs as for `configure`.
    func add(url: URL, whenSaved: () -> Void) throws {
        let didAccess = dependencies.startAccess(url)
        defer {
            if didAccess {
                dependencies.stopAccess(url)
            }
        }
        let bookmark = try url.bookmarkData(options: dependencies.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        if isChosenInThisRun(url, byAnotherThan: nil) { throw ChoiceError.duplicate }
        var updated = list
        let id = dependencies.newID()
        switch updated.add(id: id, bookmark: bookmark, name: url.lastPathComponent, path: url.path, now: dependencies.now()) {
        case .duplicate: throw ChoiceError.duplicate
        case .full: throw ChoiceError.full
        case .added: break
        }
        // The chosen path is kept, so a folder chosen again is refused before its first scan has finished; the scan then
        // writes the path it saw.
        chosenPaths[id] = QuickFolderReconnectRule.standardized(url.path)
        setList(updated)
        refresh(id)
        whenSaved()
    }

    /// "Remove Folder" (#3770) for entry 1.
    func remove() {
        if let first = list.folders.first {
            remove(first.id)
        } else {
            refresh() // no folder: cancels any scan in flight and clears the files
        }
    }

    /// "Remove Folder" for one folder. Forgets it and everything learned about it, and ends its scan. Nothing already imported is
    /// touched, and its dismissed set is kept under its path, so the same files don't come back if it is chosen again. The next
    /// folder becomes entry 1 when entry 1 goes.
    func remove(_ folderID: QuickFolderList.Entry.ID) {
        refreshTasks.removeValue(forKey: folderID)?.cancel()
        refreshIDs[folderID] = nil
        chosenPaths[folderID] = nil
        var updated = list
        updated.remove(folderID)
        setList(updated)
    }

    private func save(url: URL, into folderID: QuickFolderList.Entry.ID, keepingWhatAScanLearned: Bool, whenSaved: () -> Void) throws {
        guard let entry = list.entry(folderID) else { return }
        let didAccess = dependencies.startAccess(url)
        defer {
            if didAccess {
                dependencies.stopAccess(url)
            }
        }
        let bookmark = try url.bookmarkData(options: dependencies.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        if isChosenInThisRun(url, byAnotherThan: folderID) { throw ChoiceError.duplicate }
        var updated = list
        // The same folder chosen again, through Choose Folder or Choose Folder Again, keeps its date (#4274); a different one
        // starts its own (`repoint`).
        let now = dependencies.now()
        if case .duplicate? = updated.repoint(folderID, bookmark: bookmark, name: url.lastPathComponent, path: url.path, now: now) {
            throw ChoiceError.duplicate
        }
        updated.update(folderID) { changed in
            if changed.chosenAt == nil { changed.chosenAt = now }
            if !keepingWhatAScanLearned {
                changed.path = nil
                changed.lastCheckedAt = nil
                changed.problem = nil
            } else {
                // `repoint` stored the chosen spelling; keep the one the scan saw until the next scan writes its own.
                changed.path = entry.path
            }
        }
        chosenPaths[folderID] = QuickFolderReconnectRule.standardized(url.path)
        setList(updated)
        refresh(folderID)
        whenSaved()
    }

    /// True when another folder than `folderID` was chosen at `url`'s path in this run (the stored paths are checked by the list).
    private func isChosenInThisRun(_ url: URL, byAnotherThan folderID: QuickFolderList.Entry.ID?) -> Bool {
        let path = QuickFolderReconnectRule.standardized(url.path)
        guard !path.isEmpty else { return false }
        return list.folders.contains { $0.id != folderID && chosenPaths[$0.id] == path }
    }

    /// The saved entry 1, or nil when none is saved or the bookmark no longer resolves. A stale bookmark is refreshed in place
    /// under its own balanced scoped access. This runs on the calling actor; the refresh does its own resolving off the main
    /// actor, and only an import the listener asked for calls this, once.
    func resolvedFolderURL() -> URL? {
        syncWithStoredKeys()
        guard let first = list.folders.first else { return nil }
        return resolvedFolderURL(for: first.id)
    }

    private func resolvedFolderURL(for folderID: QuickFolderList.Entry.ID) -> URL? {
        guard let entry = list.entry(folderID) else { return nil }
        switch Self.resolve(entry.bookmark, using: dependencies) {
        case let .resolved(url, refreshedBookmark):
            if let refreshedBookmark { changeList { $0.update(folderID) { $0.bookmark = refreshedBookmark } } }
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

    /// The URLs an import of `file` needs: the file inside its own folder, and that folder, whose scoped access the import holds
    /// while it reads. Nil when its folder isn't saved or can't be resolved.
    func importURLs(for file: QuickAccessFile) -> (fileURL: URL, folderURL: URL)? {
        syncWithStoredKeys()
        guard let owner = self.folderID(of: file), let folderURL = resolvedFolderURL(for: owner) else { return nil }
        return (folderURL.appending(path: file.relativePath), folderURL)
    }

    // MARK: Refresh

    /// Rescans every folder. Per folder the newest refresh wins: a scan that finishes after a newer refresh of that folder
    /// started, or after the folder was removed, is dropped and leaves the spinner and files to the newer refresh. Each bookmark
    /// is resolved in its task, off the main actor (#3770), so a slow provider folder never holds the screen. An older build may
    /// have changed the single keys since this one last read them, so those are reconciled first.
    func refresh() {
        syncWithStoredKeys()
        guard !list.folders.isEmpty else {
            refreshTasks.values.forEach { $0.cancel() }
            refreshTasks = [:]
            refreshIDs = [:]
            if !files.isEmpty { files = [:] }
            return
        }
        for entry in list.folders { refresh(entry.id) }
    }

    /// Rescans one folder ("Check Now" on its screen).
    func refresh(_ folderID: QuickFolderList.Entry.ID) {
        guard let entry = list.entry(folderID) else { return }
        let id = UUID()
        refreshIDs[folderID] = id
        refreshTasks[folderID]?.cancel()
        files[folderID, default: FolderFiles()].isRefreshing = true
        let bookmark = entry.bookmark
        let dependencies = self.dependencies
        refreshTasks[folderID] = Task { [weak self] in
            let resolution = await Task.detached(priority: .utility) { Self.resolve(bookmark, using: dependencies) }.value
            // The task never holds its owner across the scan below: it asks the state for the folder and lets go.
            guard let folderURL = self?.folderToScan(for: resolution, folder: folderID, refreshID: id) else { return }
            let didAccess = dependencies.startAccess(folderURL)
            let scan = await dependencies.scan(folderURL)
            if didAccess {
                dependencies.stopAccess(folderURL)
            }
            guard let self, self.refreshIDs[folderID] == id else { return }
            self.finishRefresh(scan, folderURL: folderURL, folder: folderID)
        }
    }

    /// The folder to scan, or nil when this refresh is stale or the bookmark didn't resolve. An unresolved bookmark ends the
    /// refresh here: the folder's files are cleared and it is marked "can't open".
    private func folderToScan(for resolution: BookmarkResolution, folder folderID: QuickFolderList.Entry.ID, refreshID id: UUID) -> URL? {
        guard refreshIDs[folderID] == id else { return nil }
        switch resolution {
        case let .resolved(url, refreshedBookmark):
            if let refreshedBookmark { changeList { $0.update(folderID) { $0.bookmark = refreshedBookmark } } }
            return url
        case let .failed(description):
            refreshTasks[folderID] = nil
            files[folderID] = FolderFiles()
            changeList { $0.update(folderID) { $0.problem = .cantOpen } }
            recordDiagnostic("quickAccessBookmarkError", description)
            return nil
        }
    }

    private func finishRefresh(_ scan: QuickAccessFolderScan, folderURL: URL, folder folderID: QuickFolderList.Entry.ID) {
        refreshTasks[folderID] = nil
        guard let entry = list.entry(folderID) else {
            files[folderID] = nil
            return
        }
        let isPrimary = folderID == list.folders.first?.id
        if let errorDescription = scan.errorDescription {
            files[folderID] = FolderFiles()
            changeList { $0.update(folderID) { $0.problem = .cantOpen } }
            recordDiagnostic("quickAccessError", errorDescription)
            return
        }
        func file(_ found: QuickAccessFileCandidate, described: Bool = true) -> QuickAccessFile {
            QuickAccessFile(
                id: found.id,
                name: found.name,
                relativePath: found.relativePath,
                modifiedAt: found.modifiedAt,
                modifiedAtDescription: described ? Self.relativeDateFormatter.localizedString(for: found.modifiedAt, relativeTo: Date()) : ""
            )
        }
        // Following's pool carries no relative-time wording: a big folder costs no formatting on the main actor, and the
        // candidates word only the few they list.
        let found = FolderFiles(
            recentFiles: scan.files.map { file($0) },
            followingPool: QuickFolderListing.pool(newest: scan.files, all: scan.allFiles, since: entry.chosenAt).map { file($0, described: false) },
            isRefreshing: false
        )
        files[folderID] = found
        // A scan that finished is the only thing that learns where the folder is and when it was checked, and it ends "can't open".
        let checkedAt = dependencies.now()
        changeList { list in
            list.update(folderID) {
                $0.name = folderURL.lastPathComponent
                $0.path = folderURL.path
                $0.lastCheckedAt = checkedAt
                $0.problem = nil
            }
        }
        if isPrimary {
            folderName = folderURL.lastPathComponent
            recordDiagnostic("quickAccessFolder", folderURL.lastPathComponent)
            recordDiagnostic("quickAccessRecentFiles", "\(found.recentFiles.count)")
        }
        recordDiagnostic("quickFolderCount", "\(list.folders.count)")
    }

    // MARK: Saving the list

    /// Changes the list and saves it, with entry 1 written into the single keys. Nothing is published or saved when nothing changed.
    private func changeList(_ change: (inout QuickFolderList) -> Void) {
        var updated = list
        change(&updated)
        guard updated != list else { return }
        setList(updated)
    }

    /// Takes `updated` as the list after a folder was chosen, re-pointed or removed: saves it, drops a removed folder's files,
    /// and shows entry 1's name.
    private func setList(_ updated: QuickFolderList) {
        let previousFirst = list.folders.first.map { [$0.id, $0.name] }
        if updated != list {
            list = updated
            QuickFolderListStore.save(updated, to: defaults)
        }
        let kept = Set(updated.folders.map(\.id))
        let orphaned = files.keys.filter { !kept.contains($0) && !($0 == Self.noFolderKey && updated.folders.isEmpty) }
        if !orphaned.isEmpty { orphaned.forEach { files[$0] = nil } }
        if updated.folders.isEmpty {
            // With no folder the single key holds what the last folder dismissed (`QuickFolderList.mirror`).
            let kept = Set(defaults.stringArray(forKey: Self.dismissedFilesKey) ?? [])
            if kept != dismissedWithNoFolder { dismissedWithNoFolder = kept }
        }
        // Shown again only when entry 1 itself changed (chosen, renamed, removed); a scan's problem or a dismissal leaves the name
        // as it is shown.
        if updated.folders.first.map({ [$0.id, $0.name] }) != previousFirst {
            let name = Self.shownName(of: updated)
            if name != folderName { folderName = name }
        }
    }

    /// Reads the list again when an older build changed the single keys since this one wrote them (installed over this one, then
    /// this one again), or when they were written directly. Costs one small decode; reconciles and saves only on a change.
    private func syncWithStoredKeys() {
        let stored = Self.loadList(from: defaults, dependencies: dependencies)
        guard stored != list else { return }
        list = stored
        let kept = Set(stored.folders.map(\.id))
        for key in refreshTasks.keys where !kept.contains(key) {
            refreshTasks.removeValue(forKey: key)?.cancel()
            refreshIDs[key] = nil
        }
        let orphaned = files.keys.filter { !kept.contains($0) && $0 != Self.noFolderKey }
        if !orphaned.isEmpty { orphaned.forEach { files[$0] = nil } }
        if stored.folders.isEmpty {
            // An older build removed the folder: keep what it dismissed, so a later dismissal doesn't write over it.
            let keptDismissed = Set(defaults.stringArray(forKey: Self.dismissedFilesKey) ?? [])
            if keptDismissed != dismissedWithNoFolder { dismissedWithNoFolder = keptDismissed }
        }
    }

    /// The list to run on: the saved one when the single keys still say what it wrote, else the upgrade or reconcile
    /// (`QuickFolderListStore.load`, which saves it). With no saved list and no folder in the single keys, nothing is written.
    private static func loadList(from defaults: UserDefaults, dependencies: Dependencies) -> QuickFolderList {
        let stored = QuickFolderListStore.storedList(in: defaults)
        let legacy = QuickFolderListStore.legacyKeys(in: defaults)
        if let stored, stored.mirror(keepingDismissed: legacy.dismissedKeys) == legacy { return stored }
        if stored == nil, legacy.bookmark == nil {
            return QuickFolderList(retiredDismissals: QuickFolderListStore.retiredDismissals(in: defaults))
        }
        return QuickFolderListStore.load(from: defaults, now: dependencies.now(), newID: dependencies.newID)
    }

    private static func shownName(of list: QuickFolderList) -> String {
        guard let name = list.folders.first?.name, !name.isEmpty else { return noFolderName }
        return name
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
