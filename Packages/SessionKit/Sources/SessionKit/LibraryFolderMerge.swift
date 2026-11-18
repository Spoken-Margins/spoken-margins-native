import Foundation

/// What picking a folder does to its Library folder (#3769): a new pick makes a new folder; a pick of the same folder again
/// adds only what is new. Pure: it reads the walk and the folder's record and returns the record to save and the files to
/// import, so the rules are tested without a store, a file system or an importer.
///
/// "The same folder" is the same standardized path, and not a deleted folder. Then, for each file the walk found, in order:
///
/// 1. A second file in the same pick with the same bytes is named under "Couldn't add" ("Same file as “x.pdf”").
/// 2. A file whose SHA-256 matches a member is the same file, wherever it now sits: skipped. A link entry is the same by
///    its address, wherever it now sits in the list.
/// 3. A member the listener removed stays removed, whether the same bytes, a changed file at its path, or its link.
/// 4. A member that failed is tried again, with the file as it is now.
/// 5. A file at a member's path whose bytes changed is a newer copy, added right after the old one ("Updated copy").
///    The old item keeps its Margins.
/// 6. Anything else is new.
///
/// Members whose files are gone from disk stay: the items are the app's own copies.
public enum LibraryFolderMerge {
    /// A file or link entry to import, in folder order.
    public struct Job: Equatable, Sendable {
        /// The member's key in the returned record. It is the walk's key, except for a retry whose file moved (the member
        /// keeps its old key) and a newer copy (`path#updated-N`).
        public var memberKey: String
        public var walkMember: LibraryFolderWalk.Member
        /// The ID the item will be saved under, already in the record. Nil for a link and an edition, whose ID is known only
        /// once the importer returns.
        public var itemID: String?
        /// The member failed before and is being tried again.
        public var isRetry: Bool
    }

    /// Why a walk member became no job and no "Couldn't add" row. Not shown to the listener; tests read it.
    public enum Skip: Equatable, Sendable {
        /// The same bytes (or link) are already a member, under this key.
        case alreadyInFolder(memberKey: String)
        /// The same bytes or link as a member the listener removed.
        case removedFromFolder(memberKey: String)
        /// The same link twice in one pick.
        case repeatedInThisPick(walkKey: String)
    }

    public struct Result: Equatable, Sendable {
        /// Save this before importing starts. New and retried members are `adding`, with their IDs where known.
        public var record: LibraryFolderRecord
        public var jobs: [Job]
        public var skipped: [Skip]
    }

    /// The folder this pick adds to, if any: not deleted, and picked at the same standardized path. When several match,
    /// the oldest.
    public static func sameFolder(pickedPath: String, in folders: [LibraryFolderRecord]) -> LibraryFolderRecord? {
        folders
            .filter { !$0.isTrashed && $0.sourcePath == pickedPath }
            .min { ($0.importedAt, $0.id) < ($1.importedAt, $1.id) }
    }

    /// - Parameters:
    ///   - existing: the folder `sameFolder` found, or nil for a new one (then `folderID` is its new ID).
    ///   - makeItemID: gives the ID for each new text, PDF, EPUB and audio member, so it is in the record before the item exists.
    public static func merge(
        walk: LibraryFolderWalk.Result,
        pickedPath: String,
        bookmark: Data?,
        source: LibraryFolderRecord.Source,
        existing: LibraryFolderRecord?,
        folderID: String,
        now: Date,
        makeItemID: () -> String
    ) -> Result {
        var record = existing ?? LibraryFolderRecord(id: folderID, sourcePath: pickedPath, bookmark: bookmark, source: source, importedAt: now)
        if existing != nil, let bookmark { record.bookmark = bookmark }
        record.skippedOtherCount = walk.skippedOtherCount
        record.capped = walk.filesCapped || walk.entriesCapped || walk.hasDeeperFolders
        record.notAdded = walk.notAdded.map { LibraryFolderRecord.NotAdded(key: $0.key, name: $0.name, reason: $0.reason) }

        var jobs: [Job] = []
        var skipped: [Skip] = []
        var shaFirstSeenInPick: [String: String] = [:]
        var addressesInPick = Set<String>()

        for walked in walk.members {
            if walked.kind == .link {
                mergeLink(walked, into: &record, jobs: &jobs, skipped: &skipped, addressesInPick: &addressesInPick, now: now)
                continue
            }
            if let sha = walked.sha256 {
                if let firstName = shaFirstSeenInPick[sha] {
                    record.notAdded.append(.init(key: walked.key, name: fileName(walked.key), reason: "Same file as “\(firstName)”"))
                    continue
                }
                shaFirstSeenInPick[sha] = fileName(walked.key)
                if let index = record.members.firstIndex(where: { $0.sha256 == sha }) {
                    settle(index, walked: walked, into: &record, jobs: &jobs, skipped: &skipped, makeItemID: makeItemID)
                    continue
                }
            }
            if let index = latestIndex(atPath: walked.key, in: record) {
                let member = record.members[index]
                // A failed or removed member is settled by its state whatever the bytes are now. A file whose bytes can't
                // be read (a placeholder) is judged by its path alone. Otherwise the bytes differ: a newer copy.
                if member.state == .failed || member.state == .removed || walked.sha256 == nil || member.sha256 == nil {
                    settle(index, walked: walked, into: &record, jobs: &jobs, skipped: &skipped, makeItemID: makeItemID)
                    continue
                }
                addUpdatedCopy(of: index, walked: walked, into: &record, jobs: &jobs, now: now, makeItemID: makeItemID)
                continue
            }
            addNew(walked, into: &record, jobs: &jobs, now: now, makeItemID: makeItemID)
        }
        return Result(record: record, jobs: jobs, skipped: skipped)
    }

    // MARK: - Pieces

    /// A member already stands for this walk member (the same bytes, or the same path with nothing to compare). A removed
    /// or present one means skip; a failed one is tried again.
    private static func settle(
        _ index: Int, walked: LibraryFolderWalk.Member, into record: inout LibraryFolderRecord,
        jobs: inout [Job], skipped: inout [Skip], makeItemID: () -> String
    ) {
        let member = record.members[index]
        switch member.state {
        case .removed:
            skipped.append(.removedFromFolder(memberKey: member.key))
        case .added, .adding:
            skipped.append(.alreadyInFolder(memberKey: member.key))
        case .failed:
            var retried = member
            retried.state = .adding
            retried.reason = nil
            retried.retryable = false
            retried.sha256 = walked.sha256
            if retried.itemID == nil, needsPreassignedID(walked.kind) { retried.itemID = makeItemID() }
            record.members[index] = retried
            jobs.append(Job(memberKey: retried.key, walkMember: walked, itemID: retried.itemID, isRetry: true))
        }
    }

    private static func mergeLink(
        _ walked: LibraryFolderWalk.Member, into record: inout LibraryFolderRecord,
        jobs: inout [Job], skipped: inout [Skip], addressesInPick: inout Set<String>, now: Date
    ) {
        guard let address = walked.address else { return }
        guard addressesInPick.insert(address).inserted else {
            skipped.append(.repeatedInThisPick(walkKey: walked.key))
            return
        }
        guard let index = record.members.firstIndex(where: { $0.address == address }) else {
            let member = LibraryFolderRecord.Member(
                key: walked.key, kind: .link, name: walked.title ?? address, address: address, addedAt: now)
            insert(member, into: &record)
            jobs.append(Job(memberKey: member.key, walkMember: walked, itemID: nil, isRetry: false))
            return
        }
        var member = record.members[index]
        switch member.state {
        case .removed:
            skipped.append(.removedFromFolder(memberKey: member.key))
        case .added, .adding:
            skipped.append(.alreadyInFolder(memberKey: member.key))
        case .failed:
            member.state = .adding
            member.reason = nil
            member.retryable = false
            record.members[index] = member
            jobs.append(Job(memberKey: member.key, walkMember: walked, itemID: member.itemID, isRetry: true))
        }
    }

    private static func addNew(
        _ walked: LibraryFolderWalk.Member, into record: inout LibraryFolderRecord, jobs: inout [Job],
        now: Date, makeItemID: () -> String
    ) {
        let itemID = needsPreassignedID(walked.kind) ? makeItemID() : nil
        let member = LibraryFolderRecord.Member(
            key: walked.key, kind: walked.kind, name: fileName(walked.key), sha256: walked.sha256,
            itemID: itemID, addedAt: now)
        insert(member, into: &record)
        jobs.append(Job(memberKey: member.key, walkMember: walked, itemID: itemID, isRetry: false))
    }

    /// The new copy goes right after the member it replaces, and after any earlier copies of it.
    private static func addUpdatedCopy(
        of index: Int, walked: LibraryFolderWalk.Member, into record: inout LibraryFolderRecord, jobs: inout [Job],
        now: Date, makeItemID: () -> String
    ) {
        let previous = record.members[index]
        var number = 2
        while record.members.contains(where: { $0.key == "\(walked.key)#updated-\(number)" }) { number += 1 }
        let itemID = needsPreassignedID(walked.kind) ? makeItemID() : nil
        let member = LibraryFolderRecord.Member(
            key: "\(walked.key)#updated-\(number)", kind: walked.kind, name: fileName(walked.key), sha256: walked.sha256,
            itemID: itemID, addedAt: now, updatedCopyOf: previous.key)
        record.members.insert(member, at: index + 1)
        jobs.append(Job(memberKey: member.key, walkMember: walked, itemID: itemID, isRetry: false))
    }

    /// The newest member at a walk path: the one with that key, then each copy made of it, and so on.
    private static func latestIndex(atPath path: String, in record: LibraryFolderRecord) -> Int? {
        guard var current = record.members.firstIndex(where: { $0.key == path }) else { return nil }
        while let next = record.members.firstIndex(where: { $0.updatedCopyOf == record.members[current].key }) {
            current = next
        }
        return current
    }

    /// New members keep the listener's order: before the first member that sorts after them, else last. Members already
    /// in the record never move.
    private static func insert(_ member: LibraryFolderRecord.Member, into record: inout LibraryFolderRecord) {
        let at = record.members.firstIndex { other in
            NaturalPathOrder.areInIncreasingOrder(member.key, sortPath(of: other, in: record))
        } ?? record.members.count
        record.members.insert(member, at: at)
    }

    /// A copy sorts where the file it descends from does.
    private static func sortPath(of member: LibraryFolderRecord.Member, in record: LibraryFolderRecord) -> String {
        var current = member
        var steps = 0
        while let parent = current.updatedCopyOf, steps < record.members.count,
              let next = record.members.first(where: { $0.key == parent }) {
            current = next
            steps += 1
        }
        return current.key
    }

    /// Text, PDF, EPUB and audio get their item ID before the item is saved; an edition's is its content hash and a link's
    /// is known when the link import returns.
    private static func needsPreassignedID(_ kind: LibraryFolderWalk.Kind) -> Bool {
        switch kind {
        case .pdf, .text, .markdown, .epub, .audio: return true
        case .edition, .link: return false
        }
    }

    private static func fileName(_ key: String) -> String {
        (key as NSString).lastPathComponent
    }
}
