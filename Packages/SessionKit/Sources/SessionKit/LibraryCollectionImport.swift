import Foundation

/// A folder or a titled link list picked in Files becomes a collection (#3769), quietly: one collection row that fills in
/// as the files arrive, and one line when it is done, never a banner per file. Pure: it turns a walk into the collection
/// and record to save and the jobs to run, settles each job's outcome into both, and words the summary. The app runs the
/// importers; the rules are tested here without a store, a file system or an importer.
///
/// Write order (`LibraryFolderRecord`): the collection first, then the record, before the first job runs, so the row is
/// there at once and an interrupted import is settled by `LibraryFolderLaunchRule` at the next launch.
public enum LibraryCollectionImport {
    public struct Start: Equatable, Sendable {
        public var collection: ItemCollection
        public var record: LibraryFolderRecord
        /// In folder order.
        public var jobs: [LibraryFolderMerge.Job]
        /// This pick made the collection; false when it added to the collection an earlier pick of the same place made.
        public var isNew: Bool
    }

    /// How one job ended.
    public enum Outcome: Equatable, Sendable {
        case added(itemID: String)
        case failed(reason: String, retryable: Bool)
    }

    public static let fallbackName = "Imported"
    public static let notDownloadedReason = "Not downloaded from iCloud yet. Import the folder again once it is."
    public static let noItemReason = "Couldn't add this link."

    /// - Parameters:
    ///   - name: the folder's name, or the link list's title. The collection takes it, made unique among collections.
    ///   - folders: every folder record, deleted ones included. A pick of the same place adds to that collection, as long
    ///     as the collection is still there (an older build may have deleted it, leaving the record an orphan).
    ///   - collectionID: the ID a new collection takes; unused when the pick adds to an existing one.
    ///   - makeItemID: a new ID for each item whose ID is fixed before it is saved (text, PDF, EPUB, audio).
    public static func start(
        walk: LibraryFolderWalk.Result,
        pickedPath: String,
        bookmark: Data?,
        source: LibraryFolderRecord.Source = .files,
        name: String,
        folders: [LibraryFolderRecord],
        collections: [ItemCollection],
        now: Date,
        collectionID: String,
        makeItemID: () -> String
    ) -> Start {
        let livingFolders = folders.filter { folder in collections.contains { $0.id == folder.id } }
        let existing = LibraryFolderMerge.sameFolder(pickedPath: pickedPath, in: livingFolders)
        let folderID = existing?.id ?? collectionID
        let merged = LibraryFolderMerge.merge(
            walk: walk, pickedPath: pickedPath, bookmark: bookmark, source: source, existing: existing,
            folderID: folderID, now: now, makeItemID: makeItemID)
        if let existing, let collection = collections.first(where: { $0.id == existing.id }) {
            return Start(collection: collection, record: merged.record, jobs: merged.jobs, isNew: false)
        }
        let collectionName = LibraryFolderNaming.uniqueName(name, in: collections)
            ?? LibraryFolderNaming.uniqueName(fallbackName, in: collections) ?? fallbackName
        let collection = ItemCollection(id: folderID, name: collectionName, createdAt: now)
        return Start(collection: collection, record: merged.record, jobs: merged.jobs, isNew: true)
    }

    /// Records how a job ended. An added item joins the collection where the folder puts it: after the nearest member
    /// before it that is in the collection, else before the nearest one after it, else last. So a new folder fills in
    /// file order whatever order the importers finish in, a newer copy sits right after the file it replaces, and items
    /// the listener put in the collection themselves keep their places.
    public static func settle(
        _ job: LibraryFolderMerge.Job, outcome: Outcome,
        record: inout LibraryFolderRecord, collection: inout ItemCollection, now: Date
    ) {
        guard let index = record.members.firstIndex(where: { $0.key == job.memberKey }) else { return }
        var member = record.members[index]
        switch outcome {
        case .added(let itemID):
            member.state = .added
            member.itemID = itemID
            member.reason = nil
            member.retryable = false
            record.members[index] = member
            guard !collection.itemIDs.contains(itemID) else { return }
            var ids = collection.itemIDs
            if let before = record.members[..<index].reversed().compactMap(\.itemID).first(where: ids.contains),
               let at = ids.firstIndex(of: before) {
                ids.insert(itemID, at: at + 1)
            } else if let after = record.members[(index + 1)...].compactMap(\.itemID).first(where: ids.contains),
                      let at = ids.firstIndex(of: after) {
                ids.insert(itemID, at: at)
            } else {
                ids.append(itemID)
            }
            collection.itemIDs = ids
            collection.updatedAt = now
        case .failed(let reason, let retryable):
            member.state = .failed
            member.reason = reason
            member.retryable = retryable
            record.members[index] = member
        }
    }

    /// A new pick with nothing to import makes no collection: an empty row the listener never asked for would only puzzle.
    public static func savesCollection(_ start: Start) -> Bool { !(start.isNew && start.jobs.isEmpty) }

    /// The one line shown when the import is done. `added` and `failed` count this pick's jobs; `notAdded` is what the
    /// walk could not take (a packet, a second copy of a file, an unreadable `.json`).
    public struct Summary: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case success, warning, failure }
        public var message: String
        public var kind: Kind
    }

    public static func summary(name: String, isNew: Bool, added: Int, failed: Int, notAdded: Int) -> Summary {
        // A re-pick that brought nothing new and lost nothing new is up to date, even when the walk still skips files it
        // skipped the first time (a packet, a second copy): those were reported then (#3769).
        if !isNew, added == 0, failed == 0 { return Summary(message: "“\(name)” is up to date.", kind: .success) }
        let missing = failed + notAdded
        let missingWords = missing == 0 ? "" : " \(missing) couldn't be added."
        if added == 0 {
            if missing == 0 {
                return isNew
                    ? Summary(message: "There's nothing in “\(name)” the app can add.", kind: .failure)
                    : Summary(message: "“\(name)” is up to date.", kind: .success)
            }
            let what = missing == 1 ? "The 1 item in “\(name)” couldn't be added." : "None of the \(missing) items in “\(name)” could be added."
            return Summary(message: what, kind: .failure)
        }
        let items = LibraryBulkAction.items(added)
        let base = isNew ? "Made “\(name)” with \(items)." : "Added \(items) to “\(name)”."
        return Summary(message: base + missingWords, kind: missing == 0 ? .success : .warning)
    }
}
