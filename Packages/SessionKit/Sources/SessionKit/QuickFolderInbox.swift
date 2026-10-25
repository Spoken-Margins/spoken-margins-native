import Foundation

/// Which Quick Folder files the play queue takes in next (#1990 slice 3). The Quick Folder is the listener's inbox:
/// with the setting on, a file that appears in it after the setting was turned on (or after the folder was chosen)
/// is imported and queued, in filename order. Files that were already there are never swept in.
public enum QuickFolderInbox {
    public struct Plan: Equatable, Sendable {
        /// File ids (names) to add to the seen set: every current file when there was no baseline, else the files in `toImport`.
        public let newSeenKeys: Set<String>
        /// Files to import and queue, in queue order.
        public let toImport: [QuickAccessFile]
    }

    /// `seenKeys` nil means no baseline yet. A file seen before, or dismissed from Following, is skipped, so the
    /// same file is never queued twice and a file the listener dismissed stays out.
    public static func plan(files: [QuickAccessFile], seenKeys: Set<String>?, dismissedKeys: Set<String>) -> Plan {
        guard let seenKeys else {
            return Plan(newSeenKeys: Set(files.map(\.id)), toImport: [])
        }
        let fresh = files.filter { !seenKeys.contains($0.id) && !dismissedKeys.contains($0.dismissalKey) }
        return Plan(newSeenKeys: Set(fresh.map(\.id)), toImport: fresh.sorted(by: filenameOrder))
    }

    /// Filename order as a listener reads it: case-insensitive, with numbers by value ("2" before "10").
    public static func filenameOrder(_ a: QuickAccessFile, _ b: QuickAccessFile) -> Bool {
        let result = a.relativePath.compare(b.relativePath, options: [.caseInsensitive, .numeric])
        if result != .orderedSame { return result == .orderedAscending }
        return a.relativePath < b.relativePath
    }
}
