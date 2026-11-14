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
/// 2. run the delete. If it throws, the record is dropped and no file is touched;
/// 3. remove the files and drop the record. A file that can't be removed stays in the record.
///
/// On the next launch `resumePending` reads each record. If any of its items still has a row, the delete never
/// happened (the app was killed between 1 and 2), so the record is dropped and nothing is removed. Otherwise the
/// files left are removed.
///
/// A record names a file by a root's name and a path under it, never an absolute path: the app's container path can
/// change, and an absolute path read back from disk should not be trusted to point inside the app's own folders.
/// Only files strictly inside a registered root are ever removed, and a name with `..` in it is refused.
public struct PermanentDeletePurge: Sendable {
    /// A folder the purge may remove things from. `name` is what a record stores.
    public struct Root: Sendable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
    }

    /// One file or folder to remove: a path under a root.
    public struct Target: Codable, Hashable, Sendable {
        public let root: String
        public let relativePath: String
        public init(root: String, relativePath: String) { self.root = root; self.relativePath = relativePath }
    }

    /// The journal entry for one delete.
    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        public let itemIds: [String]
        public var targets: [Target]
        public let createdAt: Date
    }

    public struct Outcome: Equatable, Sendable {
        /// Targets removed now, or already gone.
        public var removed: [Target] = []
        /// Targets that could not be removed (still in their record, tried again at the next launch) or whose root
        /// this build does not know.
        public var kept: [Target] = []
        /// Records whose items still have rows, so the delete never happened: dropped, nothing removed.
        public var abandonedRecords = 0
        /// Records read and dropped because they could not be decoded.
        public var unreadableRecords = 0
        public init() {}
    }

    public let journalDirectory: URL
    public let roots: [Root]
    private let removeFile: @Sendable (URL) throws -> Void

    /// `removeFile` is the one call that deletes anything; tests pass one that fails to show a half-finished delete.
    public init(
        journalDirectory: URL, roots: [Root],
        removeFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.journalDirectory = journalDirectory
        self.roots = roots
        self.removeFile = removeFile
    }

    // MARK: Orchestration

    /// Writes the record, runs `delete`, then removes the files off the calling thread. If `delete` throws, the record
    /// is dropped, no file is touched and the error is rethrown. The returned task finishes when the removal does;
    /// callers need not wait for it. With nothing to remove, `delete` just runs.
    @discardableResult
    public func deleting(
        itemIds: [String], targets: [Target], delete: () throws -> Void
    ) throws -> Task<Outcome, Never> {
        guard !targets.isEmpty else {
            try delete()
            return Task { Outcome() }
        }
        // A journal that can't be written must not stop the delete: the files then stay, as they did before the
        // journal, and nothing the listener asked for is refused.
        guard let record = try? begin(itemIds: itemIds, targets: targets) else {
            try delete()
            return Task { Outcome() }
        }
        do {
            try delete()
        } catch {
            abandon(record)
            throw error
        }
        let purge = self
        return Task.detached(priority: .utility) { purge.finish(record) }
    }

    /// Finishes every record a killed or failed delete left. Call at launch, before the listener can delete anything.
    /// `itemExists` answers whether an item still has a row, in the trash or not; if it can't be answered, answer `true`
    /// (the record is then dropped and nothing is removed, which only ever leaves files behind).
    @discardableResult
    public func resumePending(itemExists: (String) -> Bool) -> Outcome {
        var outcome = Outcome()
        for url in recordFiles() {
            guard let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(Record.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                outcome.unreadableRecords += 1
                continue
            }
            if record.itemIds.contains(where: itemExists) {
                abandon(record)
                outcome.abandonedRecords += 1
                continue
            }
            let finished = finish(record)
            outcome.removed += finished.removed
            outcome.kept += finished.kept
        }
        return outcome
    }

    /// `resumePending` against the store's rows. An item whose row can't be read counts as present, so a failed read
    /// removes nothing.
    @discardableResult
    public func resumePending(store: SQLiteSessionStore) -> Outcome {
        resumePending(itemExists: { id in
            do { return try store.loadItemSummary(id: id) != nil } catch { return true }
        })
    }

    // MARK: Steps

    /// Writes the intent. The record is on disk when this returns.
    public func begin(itemIds: [String], targets: [Target]) throws -> Record {
        let record = Record(id: UUID().uuidString, itemIds: itemIds, targets: targets, createdAt: Date())
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
    @discardableResult
    public func finish(_ record: Record) -> Outcome {
        var outcome = Outcome()
        for target in record.targets {
            if remove(target) { outcome.removed.append(target) } else { outcome.kept.append(target) }
        }
        if outcome.kept.isEmpty {
            abandon(record)
        } else {
            var rest = record
            rest.targets = outcome.kept
            try? Self.encoder.encode(rest).write(to: file(of: rest), options: .atomic)
        }
        return outcome
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
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
