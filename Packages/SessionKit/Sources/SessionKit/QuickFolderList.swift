import Foundation

/// The listener's Quick Folders, up to `limit` of them (#3770, Design PR 4, as amended by #4274's Design section 3b item 11).
///
/// Before this list there was one Quick Folder, kept in single UserDefaults keys (`LegacyKeys`). The list is saved under
/// `quickFoldersV2`, and entry 1 keeps writing those single keys, so an older build installed over a newer one still finds the
/// first folder, its name and its dismissed files. Because an older build may then change those keys, every launch reconciles
/// them back into entry 1 (`reconciled(with:now:newID:)`).
///
/// Every folder's new files wait on Following for the listener to add; nothing queues them by itself (owner decision, #4274). So
/// an entry has no "New Files" mode, no seen-file set and no last import problem, and entry 1 never writes or takes over the
/// retired queue keys. Each entry has its own `chosenAt`, the date floor Following uses to list files past the newest eight.
///
/// Pure value logic: the app reads and writes UserDefaults through `QuickFolderListStore`, and makes and resolves bookmarks itself.
public struct QuickFolderList: Codable, Equatable, Sendable {
    /// One Quick Folder.
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// Stable for the folder's life in the list; never reused. Prefixes the folder's file ids (`qualifiedFileID`).
        public let id: String
        /// The security-scoped bookmark the app made when the folder was chosen.
        public var bookmark: Data
        /// The folder's last path component, as the listener sees it.
        public var name: String
        /// Where the last successful scan saw the folder. Nil until one has finished, or after an upgrade from a build that stored none.
        public var path: String?
        /// When this folder was chosen: Following lists files modified since then even past the newest eight (#4274). Nil reads as
        /// "no floor", so only the newest eight are listed.
        public var chosenAt: Date?
        /// When a scan last finished successfully.
        public var lastCheckedAt: Date?
        /// "Can't open this folder"; a successful scan clears it.
        public var problem: QuickFolderStatus.Problem?
        /// This folder's files dismissed from Following, as `QuickAccessFile.dismissalKey` (unprefixed).
        public var dismissedKeys: Set<String>

        public init(
            id: String,
            bookmark: Data,
            name: String,
            path: String? = nil,
            chosenAt: Date? = nil,
            lastCheckedAt: Date? = nil,
            problem: QuickFolderStatus.Problem? = nil,
            dismissedKeys: Set<String> = []
        ) {
            self.id = id
            self.bookmark = bookmark
            self.name = name
            self.path = path
            self.chosenAt = chosenAt
            self.lastCheckedAt = lastCheckedAt
            self.problem = problem
            self.dismissedKeys = dismissedKeys
        }
    }

    /// The single keys the one Quick Folder lived in before the list, as values. Read from and written to UserDefaults by
    /// `QuickFolderListStore`; entry 1 mirrors into them.
    public struct LegacyKeys: Equatable, Sendable {
        public static let bookmarkKey = "quickAccessFolderBookmark"
        public static let nameKey = "quickAccessFolderName"
        public static let pathKey = "quickAccessFolderPath"
        public static let lastCheckedAtKey = "quickAccessLastCheckedAt"
        public static let problemKey = "quickAccessFolderProblem"
        public static let dismissedKey = "dismissedQuickAccessFilesV1"
        /// Added by #4274 PR 2. Absent in builds before it.
        public static let chosenAtKey = "quickAccessFolderChosenAt"

        public var bookmark: Data?
        public var name: String?
        public var path: String?
        public var lastCheckedAt: Date?
        public var problem: QuickFolderStatus.Problem?
        public var dismissedKeys: Set<String>
        public var chosenAt: Date?

        public init(
            bookmark: Data? = nil,
            name: String? = nil,
            path: String? = nil,
            lastCheckedAt: Date? = nil,
            problem: QuickFolderStatus.Problem? = nil,
            dismissedKeys: Set<String> = [],
            chosenAt: Date? = nil
        ) {
            self.bookmark = bookmark
            self.name = name
            self.path = path
            self.lastCheckedAt = lastCheckedAt
            self.problem = problem
            self.dismissedKeys = dismissedKeys
            self.chosenAt = chosenAt
        }
    }

    /// What adding or re-pointing a folder did.
    public enum AddResult: Equatable, Sendable {
        case added(Entry.ID)
        /// That folder is already in the list, as this entry. Nothing changed.
        case duplicate(of: Entry.ID)
        /// The list already holds `limit` folders. Nothing changed.
        case full
    }

    /// At most five folders, which keeps a foreground scan of all of them cheap (Design, Default 9).
    public static let limit = 5

    /// The folders, in the order the listener added them. Entry 1 (`folders.first`) is the one mirrored into `LegacyKeys`.
    public private(set) var folders: [Entry]
    /// Dismissed sets of removed folders, by standardized path, so choosing the same folder again keeps its dismissed files. Saved
    /// under `quickFolderRetiredDismissalsV1`.
    /// A removed folder whose path was never learned is kept under `unknownPathKey`; those files stay dismissed in every folder
    /// added later (a dismissal key is a file name plus its modified time, so a false match is a file that is the same anyway).
    public private(set) var retiredDismissals: [String: Set<String>]

    /// Where `retiredDismissals` keeps the set of a removed folder whose path is unknown. Not a path: a standardized path is
    /// empty or starts with "/" or a name, never "?".
    public static let unknownPathKey = "?"

    /// `folders` is kept whole even past `limit` (a later build may allow more), so saving never drops a folder; `add` refuses one
    /// past the limit.
    public init(folders: [Entry] = [], retiredDismissals: [String: Set<String>] = [:]) {
        self.folders = folders
        self.retiredDismissals = retiredDismissals
    }

    public var isFull: Bool { folders.count >= Self.limit }

    public func entry(_ id: Entry.ID) -> Entry? { folders.first { $0.id == id } }

    /// Entries with no stored path. The app resolves their bookmarks (off the main actor) and records the path before it adds or
    /// re-points a folder, because the duplicate check can only compare paths it knows.
    public var entriesMissingPath: [Entry.ID] { folders.filter { $0.path == nil }.map(\.id) }

    // MARK: Upgrade and launch reconcile

    /// The list to run on at launch. `stored` is what `quickFoldersV2` held (nil when absent or unreadable), `legacy` the single
    /// keys as they are now.
    ///
    /// - No list yet: entry 1 is built from the legacy keys (none when no bookmark is stored). An entry built without a stored
    ///   `chosenAt` takes `now`, so a long-lived folder's old files don't come back as new.
    /// - A list: an older build may have changed the legacy keys since this build last wrote them.
    ///   - Its dismissed files are merged into entry 1's. Dismissed sets only grow, so a union is safe.
    ///   - A different bookmark is the same folder with a refreshed bookmark only on evidence: the same name, and a later scan by
    ///     the older build stored the same path (a build with #3770 PR 2 writes the path from each scan). Entry 1 then takes the
    ///     bookmark and that scan's last check and problem.
    ///   - Any other different bookmark means it chose another folder, including a same-named folder chosen by a build that never
    ///     wrote the path: entry 1 takes the bookmark and name, and what a scan learned about the old folder (path, last checked,
    ///     problem) is dropped. Mistaking the same folder for another costs only a rescan and a later date floor; the reverse would
    ///     keep a wrong path and an early floor. `chosenAt` becomes the legacy value if one is stored and
    ///     differs from entry 1's (a build with #4274 PR 2 wrote it on choosing), else `now`.
    ///   - No bookmark means it removed the folder: entry 1 is removed (`remove`, with the older build's dismissals merged in
    ///     first), and the next folder becomes entry 1.
    public static func reconciled(stored: QuickFolderList?, legacy: LegacyKeys, now: Date, newID: () -> String) -> QuickFolderList {
        guard var list = stored else {
            guard let bookmark = legacy.bookmark else { return QuickFolderList() }
            let first = Entry(
                id: newID(),
                bookmark: bookmark,
                name: legacy.name ?? "",
                path: legacy.path,
                chosenAt: legacy.chosenAt ?? now,
                lastCheckedAt: legacy.lastCheckedAt,
                problem: legacy.problem,
                dismissedKeys: legacy.dismissedKeys
            )
            return QuickFolderList(folders: [first])
        }
        guard var first = list.folders.first else {
            // Every folder was removed here; an older build chose one since.
            return reconciled(stored: nil, legacy: legacy, now: now, newID: newID).withRetired(list.retiredDismissals)
        }
        // Merged first, so files the older build dismissed before removing the folder are retired with it.
        first.dismissedKeys.formUnion(legacy.dismissedKeys)
        list.folders[0] = first
        guard let bookmark = legacy.bookmark else {
            list.remove(first.id, resolvedPath: legacy.path)
            return list
        }
        if bookmark != first.bookmark {
            first.bookmark = bookmark
            if isRefreshedBookmark(of: first, legacy: legacy) {
                first.lastCheckedAt = legacy.lastCheckedAt
                first.problem = legacy.problem
                list.folders[0] = first
                return list
            }
            if let name = legacy.name { first.name = name }
            first.path = nil
            first.lastCheckedAt = nil
            first.problem = nil
            if let legacyChosen = legacy.chosenAt, legacyChosen != first.chosenAt {
                first.chosenAt = legacyChosen
            } else {
                first.chosenAt = now
            }
        }
        list.folders[0] = first
        return list
    }

    private static func isRefreshedBookmark(of entry: Entry, legacy: LegacyKeys) -> Bool {
        guard legacy.name == nil || legacy.name == entry.name,
              let legacyPath = legacy.path, let path = entry.path,
              QuickFolderReconnectRule.standardized(legacyPath) == QuickFolderReconnectRule.standardized(path),
              let checked = legacy.lastCheckedAt, checked > (entry.lastCheckedAt ?? .distantPast) else { return false }
        return true
    }

    /// The legacy keys as entry 1 writes them. With no folders, the bookmark, name, path, times and problem are cleared and
    /// `keepingDismissed` is kept, as removing the one folder always did, so an older build doesn't bring dismissed files back.
    public func mirror(keepingDismissed previous: Set<String>) -> LegacyKeys {
        guard let first = folders.first else { return LegacyKeys(dismissedKeys: previous) }
        return LegacyKeys(
            bookmark: first.bookmark,
            name: first.name,
            path: first.path,
            lastCheckedAt: first.lastCheckedAt,
            problem: first.problem,
            dismissedKeys: first.dismissedKeys,
            chosenAt: first.chosenAt
        )
    }

    // MARK: Changing the list

    /// Adds a folder the listener chose, as the last entry. `path` is the chosen URL's path. A folder already in the list is
    /// refused (`duplicate`), and so is a sixth (`full`). A folder removed earlier gets its dismissed files back.
    @discardableResult
    public mutating func add(id: Entry.ID, bookmark: Data, name: String, path: String, now: Date) -> AddResult {
        if let existing = entry(atPath: path) { return .duplicate(of: existing.id) }
        guard !isFull else { return .full }
        let key = QuickFolderReconnectRule.standardized(path)
        var dismissed = key.isEmpty ? [] : (retiredDismissals.removeValue(forKey: key) ?? [])
        dismissed.formUnion(retiredDismissals[Self.unknownPathKey] ?? [])
        folders.append(Entry(id: id, bookmark: bookmark, name: name, path: path, chosenAt: now, dismissedKeys: dismissed))
        return .added(id)
    }

    /// "Change Folder" and "Choose Folder Again" for one entry. The same folder as the one its last scan saw
    /// (`QuickFolderReconnectRule`) keeps its last check, problem and chosen date; any other folder drops them and is chosen
    /// `now`. Either way the chosen path is stored, so the duplicate check knows it before the first scan. The dismissed set stays either way, as it always has. A folder that is already another entry is refused.
    @discardableResult
    public mutating func repoint(_ id: Entry.ID, bookmark: Data, name: String, path: String, now: Date) -> AddResult? {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return nil }
        if let existing = entry(atPath: path), existing.id != id { return .duplicate(of: existing.id) }
        var entry = folders[index]
        entry.bookmark = bookmark
        entry.name = name
        if QuickFolderReconnectRule.decide(storedPath: entry.path, chosenPath: path) == .freshBaseline {
            entry.lastCheckedAt = nil
            entry.problem = nil
            entry.chosenAt = now
        }
        entry.path = path
        folders[index] = entry
        return .added(id)
    }

    /// "Remove Folder". Its dismissed set is kept under its standardized path (merged with any already there), so choosing the same
    /// folder again doesn't bring those files back. `resolvedPath` is used when the entry has none stored; with neither, the set
    /// goes under `unknownPathKey` and stays dismissed in every folder added later. Removing entry 1 makes the next folder entry 1, which then writes the
    /// legacy keys. Returns false when there is no such entry.
    @discardableResult
    public mutating func remove(_ id: Entry.ID, resolvedPath: String? = nil) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let entry = folders.remove(at: index)
        let standardized = QuickFolderReconnectRule.standardized(entry.path ?? resolvedPath ?? "")
        let key = standardized.isEmpty ? Self.unknownPathKey : standardized
        if !entry.dismissedKeys.isEmpty {
            retiredDismissals[key, default: []].formUnion(entry.dismissedKeys)
        }
        return true
    }

    /// Changes one entry in place: a scan's result, a dismissal, a restore. The id can't change. Returns false when there is no
    /// such entry.
    @discardableResult
    public mutating func update(_ id: Entry.ID, _ change: (inout Entry) -> Void) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        var entry = folders[index]
        change(&entry)
        folders[index] = Entry(
            id: id,
            bookmark: entry.bookmark,
            name: entry.name,
            path: entry.path,
            chosenAt: entry.chosenAt,
            lastCheckedAt: entry.lastCheckedAt,
            problem: entry.problem,
            dismissedKeys: entry.dismissedKeys
        )
        return true
    }

    // MARK: File ids across folders

    /// A folder file's id that is unique across the list: entry 1's files keep their plain id, as they had with one folder, and
    /// every other folder's are `"<folder id>/<file id>"`. A Quick Folder file id is a file name, which has no "/". Removing entry
    /// 1 changes the next folder's ids to plain ones, so anything the app keys on a qualified id is rebuilt after a removal.
    public func qualifiedFileID(_ fileID: String, in folderID: Entry.ID) -> String {
        folders.first?.id == folderID ? fileID : "\(folderID)/\(fileID)"
    }

    /// The folder and plain file id behind a `qualifiedFileID`. Nil when the prefix names no folder in the list.
    public func folderAndFileID(_ qualified: String) -> (folderID: Entry.ID, fileID: String)? {
        if let slash = qualified.firstIndex(of: "/") {
            let folderID = String(qualified[..<slash])
            guard folders.dropFirst().contains(where: { $0.id == folderID }) else { return nil }
            return (folderID, String(qualified[qualified.index(after: slash)...]))
        }
        guard let first = folders.first else { return nil }
        return (first.id, qualified)
    }

    // MARK: Private

    private func entry(atPath path: String) -> Entry? {
        let key = QuickFolderReconnectRule.standardized(path)
        guard !key.isEmpty else { return nil }
        return folders.first { $0.path.map(QuickFolderReconnectRule.standardized) == key }
    }

    func withRetired(_ retired: [String: Set<String>]) -> QuickFolderList {
        var copy = self
        for (key, keys) in retired { copy.retiredDismissals[key, default: []].formUnion(keys) }
        return copy
    }
}

/// Reads and writes `QuickFolderList` and its legacy mirror in UserDefaults (#3770). The app calls `load` once at launch and
/// `save` after every change.
public enum QuickFolderListStore {
    public static let listKey = "quickFoldersV2"
    public static let retiredDismissalsKey = "quickFolderRetiredDismissalsV1"

    private struct Stored: Codable {
        var folders: [QuickFolderList.Entry]
    }

    /// The legacy single keys as they are now.
    public static func legacyKeys(in defaults: UserDefaults) -> QuickFolderList.LegacyKeys {
        typealias Keys = QuickFolderList.LegacyKeys
        return Keys(
            bookmark: defaults.data(forKey: Keys.bookmarkKey),
            name: defaults.string(forKey: Keys.nameKey),
            path: defaults.string(forKey: Keys.pathKey),
            lastCheckedAt: defaults.object(forKey: Keys.lastCheckedAtKey) as? Date,
            problem: defaults.string(forKey: Keys.problemKey).flatMap(QuickFolderStatus.Problem.init(rawValue:)),
            dismissedKeys: Set(defaults.stringArray(forKey: Keys.dismissedKey) ?? []),
            chosenAt: defaults.object(forKey: Keys.chosenAtKey) as? Date
        )
    }

    /// What `quickFoldersV2` holds, with the retired dismissals, or nil when the list was never saved or can't be read. An
    /// unreadable list is rebuilt from the legacy keys, which keeps entry 1.
    public static func storedList(in defaults: UserDefaults) -> QuickFolderList? {
        guard let data = defaults.data(forKey: listKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return QuickFolderList(folders: stored.folders, retiredDismissals: retiredDismissals(in: defaults))
    }

    /// Read on its own, so an unreadable list never wipes the retired sets when `load` saves.
    public static func retiredDismissals(in defaults: UserDefaults) -> [String: Set<String>] {
        var retired: [String: Set<String>] = [:]
        for (key, value) in defaults.dictionary(forKey: retiredDismissalsKey) ?? [:] {
            if let keys = value as? [String] { retired[key] = Set(keys) }
        }
        return retired
    }

    /// The list to run on: upgrades or reconciles (`QuickFolderList.reconciled`) and saves the result, so the next launch reads it.
    public static func load(from defaults: UserDefaults, now: Date = Date(), newID: () -> String = { UUID().uuidString }) -> QuickFolderList {
        let stored = storedList(in: defaults)
        var list = QuickFolderList.reconciled(stored: stored, legacy: legacyKeys(in: defaults), now: now, newID: newID)
        if stored == nil { list = list.withRetired(retiredDismissals(in: defaults)) }
        save(list, to: defaults)
        return list
    }

    /// Saves the list and writes entry 1 into the legacy keys.
    public static func save(_ list: QuickFolderList, to defaults: UserDefaults) {
        typealias Keys = QuickFolderList.LegacyKeys
        if let data = try? JSONEncoder().encode(Stored(folders: list.folders)) { defaults.set(data, forKey: listKey) }
        defaults.set(list.retiredDismissals.mapValues { $0.sorted() }, forKey: retiredDismissalsKey)
        let mirror = list.mirror(keepingDismissed: Set(defaults.stringArray(forKey: Keys.dismissedKey) ?? []))
        set(mirror.bookmark, Keys.bookmarkKey, defaults)
        set(mirror.name, Keys.nameKey, defaults)
        set(mirror.path, Keys.pathKey, defaults)
        set(mirror.lastCheckedAt, Keys.lastCheckedAtKey, defaults)
        set(mirror.problem?.rawValue, Keys.problemKey, defaults)
        set(mirror.chosenAt, Keys.chosenAtKey, defaults)
        defaults.set(mirror.dismissedKeys.sorted(), forKey: Keys.dismissedKey)
    }

    private static func set(_ value: Any?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

// MARK: - Following across folders (#3770, Design PR 5)

extension QuickFolderList {
    /// `file`, found in the folder `folderID` with its plain id, with the id it carries across the list (`qualifiedFileID`).
    /// Its `relativePath` stays inside its own folder.
    public func qualified(_ file: QuickAccessFile, in folderID: Entry.ID) -> QuickAccessFile {
        QuickAccessFile(
            id: qualifiedFileID(file.id, in: folderID),
            name: file.name,
            relativePath: file.relativePath,
            modifiedAt: file.modifiedAt,
            modifiedAtDescription: file.modifiedAtDescription
        )
    }

    /// The folder a listed file (with its qualified id) belongs to, and the key it is dismissed under in that folder's own
    /// `dismissedKeys` (unprefixed, as entry 1 always stored it). Nil when its id names no folder in the list.
    public func dismissal(of file: QuickAccessFile) -> (folderID: Entry.ID, key: String)? {
        guard let found = folderAndFileID(file.id) else { return nil }
        let plain = QuickAccessFile(
            id: found.fileID,
            name: file.name,
            relativePath: file.relativePath,
            modifiedAt: file.modifiedAt,
            modifiedAtDescription: file.modifiedAtDescription
        )
        return (found.folderID, plain.dismissalKey)
    }

    /// What Following lists from every folder: each folder's own first `limit` files not dismissed in that folder (`pools` holds
    /// each folder's files with plain ids, by folder id), with qualified ids, in list order. A folder with no pool lists nothing.
    public func listedFiles(
        pools: [Entry.ID: [QuickAccessFile]],
        limit: Int = QuickAccessFolderScanner.quickAddLimit
    ) -> [QuickAccessFile] {
        folders.flatMap { entry in
            QuickFolderListing.listed(pools[entry.id] ?? [], dismissedKeys: entry.dismissedKeys, limit: limit)
                .map { qualified($0, in: entry.id) }
        }
    }

    /// How many listed files (qualified ids, as `listedFiles` gives them) each folder has. Folders with none are absent.
    public func counts(of files: [QuickAccessFile]) -> [Entry.ID: Int] {
        var counts: [Entry.ID: Int] = [:]
        for file in files {
            if let folderID = folderAndFileID(file.id)?.folderID { counts[folderID, default: 0] += 1 }
        }
        return counts
    }

    /// Following's order for the folders' rows (Design, "Second step"): by name, then by readable location, then by id, so two
    /// folders never swap places between redraws.
    public var followingOrder: [Entry] {
        folders.sorted { lhs, rhs in
            let names = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric])
            if names != .orderedSame { return names == .orderedAscending }
            let left = lhs.path.flatMap(FolderLocationLabel.label(forPath:)) ?? ""
            let right = rhs.path.flatMap(FolderLocationLabel.label(forPath:)) ?? ""
            let locations = left.compare(right, options: [.caseInsensitive, .numeric])
            if locations != .orderedSame { return locations == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
