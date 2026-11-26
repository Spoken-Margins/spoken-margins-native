import Foundation
import SessionKit

/// Finishes taking an item's files off the phone after a permanent delete, even if the app is killed part way (#4227).
///
/// Permanent delete removes the item's rows in one transaction and then removes files on background tasks that
/// swallow their errors. A failure, or the app being quit, between the two left files with no row and no record to
/// finish the job. This keeps a small journal: a record naming the files is written **before** the rows go, and kept
/// until every file is gone.
///
/// The order, in `deleting`:
/// 1. write the record (the intent);
/// 2. run the delete. If it throws, no file is touched (the record stays, and is dropped at launch while the rows exist);
/// 3. remove the files and drop the record. A file that can't be removed stays in the record.
///
/// On the next launch `resumePending` reads each record. If any of its items still has a row, the delete never
/// happened (the app was killed between 1 and 2), so the record is dropped and nothing is removed. If a row can't be
/// read, the record is kept for the launch after. Otherwise the files left are removed.
///
/// A record names a file by a root's name and a path under it, never an absolute path: the app's container path can
/// change, and an absolute path read back from disk should not be trusted to point inside the app's own folders.
/// Only files strictly inside a registered root are ever removed, and a name with `..` in it is refused.
///
/// The listener's own spoken Margin recordings go through the same journal, by the audio paths their rows named
/// (`MarginRecordings`): a recording is a file only the Margin row names, so the rule is "remove it once no Margin that
/// stays names it", asked just before it goes.
public struct PermanentDeletePurge: Sendable {
    /// How the journal finds and removes the recordings of the Margins a delete took away (#4227). The app supplies the
    /// pieces that need its own layout; the rule is `MarginRecordingCleanup`'s.
    public struct MarginRecordings: Sendable {
        /// The folder recordings live under. A file outside it is never removed.
        public let directory: URL
        /// Turns a stored audio path into the file's current location, or nil when there is no such file.
        public let resolve: @Sendable (String) -> URL?
        /// Every audio path the Margins that stay name, live and quarantined. Throws when it can't be read; nothing is
        /// removed then, and the record is kept.
        public let survivingAudioPaths: @Sendable () throws -> [String]
        /// Called with each recording just before it goes (the leveled playback copies are found by the recording's
        /// content, so they must go first).
        public let beforeRemoving: @Sendable (URL) -> Void
        public init(
            directory: URL, resolve: @escaping @Sendable (String) -> URL?,
            survivingAudioPaths: @escaping @Sendable () throws -> [String],
            beforeRemoving: @escaping @Sendable (URL) -> Void = { _ in }
        ) {
            self.directory = directory
            self.resolve = resolve
            self.survivingAudioPaths = survivingAudioPaths
            self.beforeRemoving = beforeRemoving
        }
    }

    /// A folder the purge may remove things from. `name` is what a record stores.
    public struct Root: Sendable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
    }

    /// One file or folder to remove: a path under a root. `itemId` names the item the file belongs to, so a resumed
    /// delete can check that item is still gone just before it removes this file; a record without one is removed
    /// as written.
    public struct Target: Codable, Hashable, Sendable {
        public let root: String
        public let relativePath: String
        public let itemId: String?
        public init(root: String, relativePath: String, itemId: String? = nil) {
            self.root = root; self.relativePath = relativePath; self.itemId = itemId
        }
    }

    /// The journal entry for one delete.
    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        public let itemIds: [String]
        public var targets: [Target]
        /// The audio paths of the Margin recordings the delete took away, as their rows stored them. Nil in a record
        /// from a build that kept none, which decodes the same.
        public var recordingPaths: [String]?
        public let createdAt: Date
    }

    public struct Outcome: Equatable, Sendable {
        /// Targets removed now, or already gone.
        public var removed: [Target] = []
        /// Targets that could not be removed (still in their record, tried again at the next launch) or whose root
        /// this build does not know.
        public var kept: [Target] = []
        /// Targets left alone because their item came back (a re-import of the same id) after the record was read:
        /// dropped from the record, nothing removed.
        public var reappeared: [Target] = []
        /// Records whose items still have rows, so the delete never happened: dropped, nothing removed.
        public var abandonedRecords = 0
        /// Records read and dropped because they could not be decoded.
        public var unreadableRecords = 0
        /// Records left untouched because an item's row could not be read.
        public var deferredRecords = 0
        /// Margin recordings removed now, or already gone or kept by a Margin that stays.
        public var recordingsDone = 0
        /// Margin recordings left in their record: a removal failed, the Margins that stay couldn't be read, or this
        /// build has no way to find recordings.
        public var recordingsKept = 0
        public init() {}
    }

    public let journalDirectory: URL
    public let roots: [Root]
    public let marginRecordings: MarginRecordings?
    private let removeFile: @Sendable (URL) throws -> Void

    /// `removeFile` is the one call that deletes anything; tests pass one that fails to show a half-finished delete.
    /// Without `marginRecordings`, a record's recording paths are kept for a launch that has them.
    public init(
        journalDirectory: URL, roots: [Root], marginRecordings: MarginRecordings? = nil,
        removeFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.journalDirectory = journalDirectory
        self.roots = roots
        self.marginRecordings = marginRecordings
        self.removeFile = removeFile
    }

    // MARK: Orchestration

    /// Writes the record, runs `delete`, then removes the files off the calling thread. If `delete` throws, no file is
    /// touched and the error is rethrown; the record stays, because a throw after the commit would leave the rows gone,
    /// and the next launch's `resumePending` drops it when the items still have rows. The returned task finishes when
    /// the removal does; callers need not wait for it. With nothing to remove, `delete` just runs.
    ///
    /// `recheck`, if given, runs on the background task just before each file is removed (see `finish`), so a read of
    /// the store for it never waits on the calling thread.
    ///
    /// `recordingPaths` are the audio paths of the Margins the delete takes away, read before it. They are not resolved
    /// here, so the calling thread does no file work for them; the removal step resolves them.
    @discardableResult
    public func deleting(
        itemIds: [String], targets: [Target], recordingPaths: [String] = [],
        recheck: (@Sendable (Target) -> RowState)? = nil, delete: () throws -> Void
    ) throws -> Task<Outcome, Never> {
        let recordingPaths = Self.distinct(recordingPaths)
        guard !targets.isEmpty || !recordingPaths.isEmpty else {
            try delete()
            return Task { Outcome() }
        }
        // A journal that can't be written must not stop the delete. The item's files then stay, as they did before the
        // journal. The recordings are still removed, with no record behind them, as they were before it: nothing the
        // listener asked for is refused, and their removal never waited on a record.
        guard let record = try? begin(itemIds: itemIds, targets: targets, recordingPaths: recordingPaths) else {
            try delete()
            guard !recordingPaths.isEmpty else { return Task { Outcome() } }
            let unwritten = Record(
                id: UUID().uuidString, itemIds: itemIds, targets: [], recordingPaths: recordingPaths, createdAt: Date())
            let purge = self
            return Task.detached(priority: .utility) { purge.finish(unwritten) }
        }
        try delete()
        let purge = self
        return Task.detached(priority: .utility) { purge.finish(record, recheck: recheck) }
    }

    /// Whether an item still has a row, in the trash or not.
    public enum RowState: Sendable, Equatable {
        case present, absent
        /// The answer could not be read (a busy database). The record is kept for the next launch.
        case unknown
    }

    /// Finishes the records a killed or failed delete left. Call at launch. A record made after `cutoff` belongs to a
    /// delete running in this process, which finishes it itself, so it is left alone: pass the moment the launch began.
    ///
    /// For each record: if any item `rowState` calls present, the delete never happened and the record is dropped;
    /// otherwise, if any is unknown, the record is kept untouched; otherwise its files are removed.
    @discardableResult
    public func resumePending(
        recordsBefore cutoff: Date, rowState: @escaping (String) -> RowState,
        recheck: ((Target) -> RowState)? = nil
    ) -> Outcome {
        var outcome = Outcome()
        // Unless the caller says otherwise, each file is checked again by its item's row alone.
        let recheck: (Target) -> RowState = recheck ?? { target in target.itemId.map(rowState) ?? .absent }
        for url in recordFiles() {
            guard let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(Record.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                outcome.unreadableRecords += 1
                continue
            }
            if record.createdAt > cutoff { continue }
            let states = record.itemIds.map(rowState)
            if states.contains(where: { if case .present = $0 { true } else { false } }) {
                abandon(record)
                outcome.abandonedRecords += 1
                continue
            }
            if states.contains(where: { if case .unknown = $0 { true } else { false } }) {
                outcome.kept += record.targets
                outcome.recordingsKept += record.recordingPaths?.count ?? 0
                outcome.deferredRecords += 1
                continue
            }
            let finished = finish(record, recheck: recheck)
            outcome.removed += finished.removed
            outcome.kept += finished.kept
            outcome.reappeared += finished.reappeared
            outcome.recordingsDone += finished.recordingsDone
            outcome.recordingsKept += finished.recordingsKept
        }
        return outcome
    }

    /// `resumePending` against the store's rows. A quarantined item row counts as present: it can be restored, and
    /// its files are its own. Just before a prepared-audio folder goes, every item id is read again, in case another
    /// id that maps to the same folder was imported since the delete.
    @discardableResult
    public func resumePending(recordsBefore cutoff: Date, store: SQLiteSessionStore) -> Outcome {
        resumePending(
            recordsBefore: cutoff, rowState: { ItemOwnedFiles.rowState(ofItem: $0, in: store) },
            recheck: storeRecheck(store: store))
    }

    /// `ItemOwnedFiles.stillFree` against the store's rows, for the removal step, which runs off the calling thread. A
    /// quarantined item row counts as present: it can be restored, and its files are its own. A row that can't be read
    /// (a busy database) is `unknown`, which keeps the file for the next launch. Whether the prepared-audio folder's
    /// volume is case-sensitive is looked up when a folder target is met, on the removal step's own thread.
    public func storeRecheck(store: SQLiteSessionStore) -> @Sendable (Target) -> RowState {
        let purge = self
        return { target in
            ItemOwnedFiles.stillFree(
                target, rowState: { ItemOwnedFiles.rowState(ofItem: $0, in: store) },
                allItemIds: { try store.loadAllItemIds() },
                caseSensitiveNames: ItemOwnedFiles.isSharedFolderRoot(target.root) && purge.rootIsCaseSensitive(target.root))
        }
    }

    /// Whether the volume holding the named root treats case as different (false when unknown).
    public func rootIsCaseSensitive(_ rootName: String) -> Bool {
        roots.first { $0.name == rootName }.map { ItemOwnedFiles.volumeIsCaseSensitive(at: $0.url) } ?? false
    }

    // MARK: Steps

    /// Writes the intent. The record is on disk when this returns.
    public func begin(itemIds: [String], targets: [Target], recordingPaths: [String] = []) throws -> Record {
        let record = Record(
            id: UUID().uuidString, itemIds: itemIds, targets: targets,
            recordingPaths: recordingPaths.isEmpty ? nil : Self.distinct(recordingPaths), createdAt: Date())
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: file(of: record), options: .atomic)
        return record
    }

    /// The delete did not happen: drops the record.
    public func abandon(_ record: Record) {
        try? FileManager.default.removeItem(at: file(of: record))
    }

    /// Removes the record's files. The record goes when every file is gone; otherwise it is rewritten with only the
    /// files left, so the next launch tries those again.
    ///
    /// With `recheck`, each file's item is looked up again just before that file is removed (a launch can finish a
    /// record while the listener imports the same item again, which gives it the same id and the same file names): an
    /// item that is present again keeps its file and the target is dropped, and one that can't be read keeps the
    /// target for the next launch. This narrows the window to the one lookup before the removal; it does not close it.
    @discardableResult
    public func finish(_ record: Record, recheck: ((Target) -> RowState)? = nil) -> Outcome {
        var outcome = Outcome()
        for target in record.targets {
            if let recheck {
                switch recheck(target) {
                case .present: outcome.reappeared.append(target); continue
                case .unknown: outcome.kept.append(target); continue
                case .absent: break
                }
            }
            if remove(target) { outcome.removed.append(target) } else { outcome.kept.append(target) }
        }
        let recordings = record.recordingPaths ?? []
        let keptRecordings = finishRecordings(recordings)
        outcome.recordingsDone = recordings.count - keptRecordings.count
        outcome.recordingsKept = keptRecordings.count
        if outcome.kept.isEmpty && keptRecordings.isEmpty {
            abandon(record)
        } else {
            var rest = record
            rest.targets = outcome.kept
            rest.recordingPaths = keptRecordings.isEmpty ? nil : keptRecordings
            try? Self.encoder.encode(rest).write(to: file(of: rest), options: .atomic)
        }
        return outcome
    }

    /// Removes the recordings the Margins that stay don't name, and returns the paths to keep in the record. A path
    /// with no file, one outside the recordings folder, and one a surviving Margin names are finished: nothing is
    /// removed for them (`MarginRecordingCleanup`'s rule). A recording that can't be removed is kept for the next
    /// launch; so is every path when the Margins that stay can't be read, or when this build can't find recordings.
    private func finishRecordings(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }
        guard let config = marginRecordings, let surviving = try? config.survivingAudioPaths() else { return paths }
        var stuck: Set<String> = []
        for file in MarginRecordingCleanup.filesToRemove(
            deletedAudioPaths: paths, survivingAudioPaths: surviving, within: config.directory, resolve: config.resolve
        ) {
            config.beforeRemoving(file)
            do { try removeFile(file) } catch { stuck.insert(file.path) }
        }
        guard !stuck.isEmpty else { return [] }
        return paths.filter { path in
            guard let url = config.resolve(path) else { return false }
            return stuck.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }

    private static func distinct(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: Files

    /// Removes one target. A target that is already gone counts as removed. A target whose root is unknown, whose
    /// path climbs out of its root, or that resolves outside it is refused and counts as kept.
    private func remove(_ target: Target) -> Bool {
        guard let url = resolve(target) else { return false }
        let manager = FileManager.default
        // `fileExists` follows a link; a dangling link still has to be removed.
        guard (try? manager.attributesOfItem(atPath: url.path)) != nil else { return true }
        do {
            try removeFile(url)
            return true
        } catch {
            return false
        }
    }

    /// The file a target names, if it is strictly inside its root once links in its parent folders are resolved.
    /// The last component is not resolved: removing a link removes the link, never what it points at.
    func resolve(_ target: Target) -> URL? {
        guard let root = roots.first(where: { $0.name == target.root }) else { return nil }
        let parts = target.relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !target.relativePath.hasPrefix("/"),
              !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let resolvedRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
        var parent = resolvedRoot
        for part in parts.dropLast() { parent = parent.appending(path: part, directoryHint: .isDirectory) }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard (resolvedParent.path + "/").hasPrefix(rootPath) else { return nil }
        return resolvedParent.appending(path: parts[parts.count - 1])
    }

    private func recordFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: journalDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { journalDirectory.appending(path: $0) }
    }

    private func file(of record: Record) -> URL {
        journalDirectory.appending(path: record.id + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
