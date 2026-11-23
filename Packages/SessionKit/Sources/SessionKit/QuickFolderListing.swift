import Foundation

/// Which Quick Folder files Following may list (#4274): the scan's newest few, as before, plus every file past them modified
/// since the folder was chosen, so a burst of new files is never cut off and a long-lived folder's old files don't come back.
public enum QuickFolderListing {
    /// `newest` plus the files in `all` with `modifiedAt >= since`, once each (by `id`), newest first (ties by `id`).
    /// With `since == nil`, `newest` unchanged.
    public static func pool(newest: [QuickAccessFileCandidate], all: [QuickAccessFileCandidate], since: Date?) -> [QuickAccessFileCandidate] {
        guard let since else { return newest }
        var seen = Set<String>()
        let merged = (newest + all.filter { $0.modifiedAt >= since }).filter { seen.insert($0.id).inserted }
        return merged.sorted {
            $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.id < $1.id
        }
    }

    /// The first `limit` files of `pool` whose `dismissalKey` is not in `dismissedKeys`, in pool order.
    public static func listed(
        _ pool: [QuickAccessFile],
        dismissedKeys: Set<String>,
        limit: Int = QuickAccessFolderScanner.quickAddLimit
    ) -> [QuickAccessFile] {
        Array(pool.lazy.filter { !dismissedKeys.contains($0.dismissalKey) }.prefix(max(0, limit)))
    }
}
