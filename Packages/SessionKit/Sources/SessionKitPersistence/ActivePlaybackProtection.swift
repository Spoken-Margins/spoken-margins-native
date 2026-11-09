import Foundation
import SessionKit

/// Moves the `activePlayback` protection on podcast ledger rows to the episode now playing (#287, #530, #3752).
///
/// The protection must be in the ledger before any eviction that follows, so this runs on the caller's thread and
/// finishes before it returns. What changed in #3752 is the read: it used to decode every ledger row of every category to
/// find the one or two rows to change, and the Build 36 export shows that read, with its writes, holding the main thread for
/// up to 2.4 s as a podcast started. It now asks SQLite for just the rows that can change, and labels the read and the
/// writes apart, so the next export says which half costs.
public enum ActivePlaybackProtection {
    public static let readLabel = "offlineAssets.read"
    public static let writeLabel = "offlineAssets.write"

    /// Makes `itemId`'s podcast rows (and the row at `activePath`) the only ones carrying `activePlayback`; with a nil
    /// `itemId` it takes the protection off every row. Returns how many rows it changed.
    @discardableResult
    public static func move(
        in store: SQLiteSessionStore, toItem itemId: String?, activePath: String?,
        labels: MainThreadOperationLabels = .shared
    ) -> Int {
        let candidates = labels.scoped(readLabel) {
            (try? store.loadOwnedOfflineAssets(
                category: .podcast, itemId: itemId, relativePath: activePath, holding: .activePlayback
            )) ?? []
        }
        var changed = 0
        for asset in candidates {
            let isActive = itemId != nil && (asset.itemId == itemId
                || (activePath != nil && asset.relativePath == activePath))
            let wasActive = asset.protections.contains(.activePlayback)
            guard isActive != wasActive else { continue }
            // One atomic row update, so a ledger reconcile can't write back a copy without it (#287).
            let saved = labels.scoped(writeLabel) {
                try? store.updateOwnedOfflineAsset(id: asset.id) { current in
                    if isActive { current.protections.insert(.activePlayback) }
                    else { current.protections.remove(.activePlayback) }
                }
            }
            if saved != nil { changed += 1 }
        }
        return changed
    }
}
