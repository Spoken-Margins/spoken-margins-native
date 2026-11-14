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

    /// Every file the item owns alone. The prepared-audio folder is named from the id by a lossy rule, so two ids can
    /// map to one folder (`a-b` and `a_b`; an 80-character id and a longer one that starts with it). It is named here
    /// only when no id in `otherItemIds` (the other items that still have rows) maps to the same folder, so a purge
    /// never takes another item's narration chunks. An empty id has no folder.
    public static func targets(forItem itemId: String, otherItemIds: [String] = []) -> [PermanentDeletePurge.Target] {
        targets(forItems: [itemId], existingItemIds: otherItemIds + [itemId])
    }

    /// The files of `itemIds`, which are being deleted together. `existingItemIds` is every id that has a row now
    /// (the ids being deleted may be in it): the ones not being deleted decide which prepared-audio folders are shared.
    /// `namingPreparedAudio: false` leaves every prepared-audio folder out, for a caller that couldn't read the ids.
    public static func targets(
        forItems itemIds: [String], existingItemIds: [String], namingPreparedAudio: Bool = true
    ) -> [PermanentDeletePurge.Target] {
        // Ids are the same only when their bytes are (SQLite compares bytes; Swift's `==` also joins canonically
        // equivalent spellings, which would drop a staying id that merely looks like a deleted one).
        let deleting = Set(itemIds.map { Array($0.utf8) })
        let staying = Set(existingItemIds.filter { !deleting.contains(Array($0.utf8)) }.map(folderKey(itemId:)))
        var targets: [PermanentDeletePurge.Target] = []
        var folders: Set<String> = []
        for itemId in itemIds {
            targets.append(.init(
                root: listeningEditionsRoot, relativePath: listeningEditionFileName(itemId: itemId), itemId: itemId))
            let folder = preparedAudioDirectoryName(itemId: itemId)
            if namingPreparedAudio, !itemId.isEmpty, !staying.contains(folderKey(itemId: itemId)), folders.insert(folder).inserted {
                targets.append(.init(root: preparedAudioRoot, relativePath: folder, itemId: itemId))
            }
        }
        return targets
    }
}
