import Foundation
import SessionKit

/// The files that belong to one item alone, named for `PermanentDeletePurge` (#4227).
///
/// Each rule here is the same rule the writer uses to place the file, so the two cannot drift apart: the writers
/// (`PreparedAudioCoordinator`, `ListeningEditionStore`) call these functions to build their paths.
///
/// Only an item's own files are named here, never a shared one: the rendered-speech cache and the artwork cache are
/// keyed by content, so another item can use the same file.
public enum ItemOwnedFiles {
    /// Root names a record uses. The app registers each against its folder.
    public static let preparedAudioRoot = "PreparedAudio"
    public static let listeningEditionsRoot = "ListeningEditions"

    /// The folder name of an item's prepared narration chunks under `PreparedAudio/`. Letters and digits are kept,
    /// everything else becomes `-`, and the name is cut at 80 characters.
    public static func preparedAudioDirectoryName(itemId: String) -> String {
        String(itemId.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(80))
    }

    /// The file name of an item's saved Listening Edition under `ListeningEditions/`.
    public static func listeningEditionFileName(itemId: String) -> String {
        ListeningEdition.digest(itemId) + ".json"
    }

    /// What two ids are compared by when asking whether they share a folder: the folder name, lower-cased, because
    /// the volume (APFS) is case-insensitive by default, so `A-1` and `a-1` are one directory.
    public static func folderKey(itemId: String) -> String {
        preparedAudioDirectoryName(itemId: itemId).lowercased()
    }

    /// Whether `target` is still free to remove, asked just before it is removed on a resumed delete: its item has no
    /// row, and, for a prepared-audio folder, no item at all has a row that maps to the folder (another id may have
    /// been imported since, and `allItemIds` is read only when a folder target is met).
    public static func stillFree(
        _ target: PermanentDeletePurge.Target, rowState: (String) -> PermanentDeletePurge.RowState,
        allItemIds: () throws -> [String]
    ) -> PermanentDeletePurge.RowState {
        if let itemId = target.itemId {
            let own = rowState(itemId)
            if own != .absent { return own }
        }
        guard target.root == preparedAudioRoot else { return .absent }
        guard let ids = try? allItemIds() else { return .unknown }
        let key = target.relativePath.lowercased()
        return ids.contains { folderKey(itemId: $0) == key } ? .present : .absent
    }

    /// `stillFree` against the store's rows, for `PermanentDeletePurge`'s removal step, which runs off the calling thread.
    /// A quarantined item row counts as present: it can be restored, and its files are its own. A row that can't be read
    /// (a busy database) is `unknown`, which keeps the file for the next launch.
    public static func recheck(store: SQLiteSessionStore) -> @Sendable (PermanentDeletePurge.Target) -> PermanentDeletePurge.RowState {
        { target in
            stillFree(
                target, rowState: { id in rowState(ofItem: id, in: store) }, allItemIds: { try store.loadAllItemIds() })
        }
    }

    public static func rowState(ofItem id: String, in store: SQLiteSessionStore) -> PermanentDeletePurge.RowState {
        do { return try store.hasItemRow(id: id) ? .present : .absent } catch { return .unknown }
    }

    /// Every file the items own, as a record names them. A prepared-audio folder is named for every non-empty id, even
    /// though the lossy name can be shared (`a-b` and `a_b`; an 80-character id and a longer one that starts with it):
    /// whether the folder is still free is decided just before it is removed, by `stillFree`, so a purge never takes
    /// another item's narration chunks and the delete itself reads nothing from the store.
    public static func targets(forItems itemIds: [String]) -> [PermanentDeletePurge.Target] {
        var targets: [PermanentDeletePurge.Target] = []
        var folders: Set<String> = []
        for itemId in itemIds {
            targets.append(.init(
                root: listeningEditionsRoot, relativePath: listeningEditionFileName(itemId: itemId), itemId: itemId))
            let folder = preparedAudioDirectoryName(itemId: itemId)
            if !itemId.isEmpty, folders.insert(folderKey(itemId: itemId)).inserted {
                targets.append(.init(root: preparedAudioRoot, relativePath: folder, itemId: itemId))
            }
        }
        return targets
    }

    public static func targets(forItem itemId: String) -> [PermanentDeletePurge.Target] {
        targets(forItems: [itemId])
    }
}
