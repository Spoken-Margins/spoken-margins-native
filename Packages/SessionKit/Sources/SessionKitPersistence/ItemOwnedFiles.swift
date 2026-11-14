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

    /// What two ids are compared by when asking whether they share a folder: the folder name, and, on a volume that
    /// treats case as the same (`caseSensitiveNames` false, the safe answer when it is not known), the lower-cased name,
    /// because `A-1` and `a-1` are then one directory.
    public static func folderKey(itemId: String, caseSensitiveNames: Bool) -> String {
        let name = preparedAudioDirectoryName(itemId: itemId)
        return caseSensitiveNames ? name : name.lowercased()
    }

    /// Whether the volume holding `directory` treats `A` and `a` as different names. Unknown (a missing folder, a platform
    /// that doesn't say) is false: the folder is then kept when another id could share it, never removed.
    public static func volumeIsCaseSensitive(at directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
    }

    /// Whether `target` is still free to remove, asked just before it is removed on a resumed delete: its item has no
    /// row, and, for a prepared-audio folder, no item at all has a row that maps to the folder (another id may have
    /// been imported since, and `allItemIds` is read only when a folder target is met).
    public static func stillFree(
        _ target: PermanentDeletePurge.Target, rowState: (String) -> PermanentDeletePurge.RowState,
        allItemIds: () throws -> [String], caseSensitiveNames: Bool = false
    ) -> PermanentDeletePurge.RowState {
        if let itemId = target.itemId {
            let own = rowState(itemId)
            if own != .absent { return own }
        }
        guard target.root == preparedAudioRoot else { return .absent }
        guard let ids = try? allItemIds() else { return .unknown }
        let key = caseSensitiveNames ? target.relativePath : target.relativePath.lowercased()
        return ids.contains { folderKey(itemId: $0, caseSensitiveNames: caseSensitiveNames) == key } ? .present : .absent
    }

    public static func rowState(ofItem id: String, in store: SQLiteSessionStore) -> PermanentDeletePurge.RowState {
        do { return try store.hasItemRow(id: id) ? .present : .absent } catch { return .unknown }
    }

    /// Every file the items own, as a record names them. A prepared-audio folder is named for every non-empty id, even
    /// though the lossy name can be shared (`a-b` and `a_b`; an 80-character id and a longer one that starts with it):
    /// whether the folder is still free is decided just before it is removed, by `stillFree`, so a purge never takes
    /// another item's narration chunks and the delete itself reads nothing from the store. Only exactly equal folder
    /// names are listed once: ids that differ by case alone are listed separately, so on a case-sensitive volume each
    /// folder is named in the record, and on a case-insensitive one the second removal finds the folder already gone.
    public static func targets(forItems itemIds: [String]) -> [PermanentDeletePurge.Target] {
        var targets: [PermanentDeletePurge.Target] = []
        var folders: Set<String> = []
        for itemId in itemIds {
            targets.append(.init(
                root: listeningEditionsRoot, relativePath: listeningEditionFileName(itemId: itemId), itemId: itemId))
            let folder = preparedAudioDirectoryName(itemId: itemId)
            if !itemId.isEmpty, folders.insert(folder).inserted {
                targets.append(.init(root: preparedAudioRoot, relativePath: folder, itemId: itemId))
            }
        }
        return targets
    }

    public static func targets(forItem itemId: String) -> [PermanentDeletePurge.Target] {
        targets(forItems: [itemId])
    }
}
