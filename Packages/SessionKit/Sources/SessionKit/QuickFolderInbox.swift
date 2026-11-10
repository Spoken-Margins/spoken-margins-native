import Foundation

/// Which Quick Folder files the play queue takes in next (#1990 slice 3). The Quick Folder is the listener's inbox:
/// with the setting on, a file that appears in it after the setting was turned on (or after the folder was chosen)
/// is imported and queued, in filename order. Files that were already there are never swept in.
public enum QuickFolderInbox {
    /// How many files one import pass takes. A bigger batch arrives over several passes, each one picking up the files
    /// the last left unseen, still in filename order overall (#3767).
    public static let batchSize = 8

    public struct Plan: Equatable, Sendable {
        /// File ids (names) to add to the seen set: every current file when there was no baseline, else the files in `toImport`.
        public let newSeenKeys: Set<String>
        /// Files to import and queue, in queue order: the first `batchSize` unseen files by filename.
        public let toImport: [QuickAccessFile]
        /// Files to add to the seen set without importing them: see `seenCoversWholeFolder`.
        public let grandfatheredKeys: Set<String>
    }

    /// `seenKeys` nil means no baseline yet. A file seen before, or dismissed from Following, is skipped, so the
    /// same file is never queued twice and a file the listener dismissed stays out.
    ///
    /// `files` is the whole folder. Builds before #3767 gave the inbox only the eight newest files, so a baseline taken
    /// by one of them lists at most those eight and every older file is "unseen" now that the inbox sees them all.
    /// `seenCoversWholeFolder` false says that: the files outside the newest eight are marked seen, not queued, because
    /// they were there before (or were skipped, which this cannot tell apart, and not sweeping in a listener's old files
    /// is the safe side). The caller stores `true` once a plan has run on a scan that worked.
    public static func plan(
        files: [QuickAccessFile], seenKeys: Set<String>?, dismissedKeys: Set<String>, seenCoversWholeFolder: Bool = true
    ) -> Plan {
        guard let seenKeys else {
            return Plan(newSeenKeys: Set(files.map(\.id)), toImport: [], grandfatheredKeys: [])
        }
        var grandfathered: Set<String> = []
        if !seenCoversWholeFolder {
            let newestFirst = files.sorted {
                $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.relativePath < $1.relativePath
            }
            grandfathered = Set(newestFirst.dropFirst(QuickAccessFolderScanner.quickAddLimit).map(\.id)).subtracting(seenKeys)
        }
        let seen = seenKeys.union(grandfathered)
        let fresh = files.filter { !seen.contains($0.id) && !dismissedKeys.contains($0.dismissalKey) }
        let batch = Array(fresh.sorted(by: filenameOrder).prefix(batchSize))
        return Plan(newSeenKeys: Set(batch.map(\.id)), toImport: batch, grandfatheredKeys: grandfathered)
    }

    /// Filename order as a listener reads it: case-insensitive, with numbers by value ("2" before "10").
    public static func filenameOrder(_ a: QuickAccessFile, _ b: QuickAccessFile) -> Bool {
        let result = a.relativePath.compare(b.relativePath, options: [.caseInsensitive, .numeric])
        if result != .orderedSame { return result == .orderedAscending }
        return a.relativePath < b.relativePath
    }
}
