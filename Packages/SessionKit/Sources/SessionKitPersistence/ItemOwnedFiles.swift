import Foundation
import SessionKit

/// The files that belong to one item alone, named for `PermanentDeletePurge` (#4227).
///
/// Each rule here is the same rule the writer uses to place the file, so the two cannot drift apart: the writers
/// (`PreparedAudioCoordinator`, `ListeningEditionStore`) call these functions to build their paths.
///
/// Only an item's own files are named here, never a shared one: the rendered-speech cache and the artwork cache are
/// keyed by content, so another item can use the same file.
///
/// The files the app copied in from Files (an EPUB, an audiobook) are found by the item's ledger rows, which are read
/// before the delete takes them, and kept only when the row names exactly the file the importer writes for that item.
/// A row with any other path is left alone, so a damaged or foreign row can never point a delete at another file.
public enum ItemOwnedFiles {
    /// Root names a record uses. The app registers each against its folder.
    public static let preparedAudioRoot = "PreparedAudio"
    public static let listeningEditionsRoot = "ListeningEditions"
    /// `SourceDocuments/` and `Audiobooks/` under Application Support: the copies `LocalSourceImporter` makes.
    public static let sourceDocumentsRoot = "SourceDocuments"
    public static let audiobooksRoot = "Audiobooks"
    /// `SpokenMargins/EpisodeMaps/` under Application Support: one folder per item.
    public static let episodeMapsRoot = "EpisodeMaps"
    /// `ItemOriginals/` under Application Support: the PDF the listener added, one folder per item (`PDFOriginalStore`, #4338).
    public static let itemOriginalsRoot = "ItemOriginals"

    /// The folder name of an item's kept original PDF under `ItemOriginals/`: a digest of the id, so no two ids share a
    /// folder and no id can name a path. Nil for an empty id. `PDFOriginalStore` writes to this folder.
    public static func itemOriginalsFolderName(itemId: String) -> String? {
        itemId.isEmpty ? nil : ListeningEdition.digest(itemId)
    }

    /// `SpokenMargins/PDFClips/` under Application Support: one folder per item, holding the pictures of a PDF's tables
    /// and figures that its Timeline shows (#3895).
    public static let pdfClipsRoot = "PDFClips"

    /// The audio file types `LocalSourceImporter.importAudiobook` accepts (and writes, lower-cased).
    static let audiobookExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4"]

    /// The folder name of an item's episode-map files under `SpokenMargins/EpisodeMaps/`. Nil when the id has no folder
    /// of its own: an empty id would name `unknown`, and `.` or `..` would name the folder itself or its parent.
    public static func episodeMapDirectoryName(itemId: String) -> String? {
        guard !itemId.isEmpty else { return nil }
        let name = PodcastAnchorEvidencePaths.safeComponent(itemId)
        return name == "." || name == ".." ? nil : name
    }

    /// The folder name of an item's PDF clips under `SpokenMargins/PDFClips/`, made the way the episode-map folder's is:
    /// nil when the id has no folder of its own.
    public static func pdfClipDirectoryName(itemId: String) -> String? {
        episodeMapDirectoryName(itemId: itemId)
    }

    /// The copied source file a ledger row names, as a target, if the row is the one the importer writes for `itemId`:
    /// category `sourceDocument` at `SourceDocuments/<id>.epub`, or `audiobook` at `Audiobooks/<id>.<mp3|m4a|m4b|mp4>`.
    /// Anything else (another item's row, another category, a nested or differently named path) is nil.
    public static func copiedSourceTarget(
        forAsset asset: OwnedOfflineAsset, ofItem itemId: String
    ) -> PermanentDeletePurge.Target? {
        guard !itemId.isEmpty, asset.itemId == itemId else { return nil }
        let root: String
        switch asset.category {
        case .sourceDocument: root = sourceDocumentsRoot
        case .audiobook: root = audiobooksRoot
        default: return nil
        }
        let prefix = root + "/"
        guard asset.relativePath.hasPrefix(prefix) else { return nil }
        let name = String(asset.relativePath.dropFirst(prefix.count))
        let stem = itemId + "."
        guard name.hasPrefix(stem) else { return nil }
        let ext = String(name.dropFirst(stem.count))
        let allowed = asset.category == .sourceDocument ? ext == "epub" : audiobookExtensions.contains(ext)
        guard allowed else { return nil }
        return .init(root: root, relativePath: name, itemId: itemId)
    }

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
    /// row, and, for a folder whose name is made from the id (prepared audio, episode maps), no item at all has a row
    /// that maps to the folder (another id may have been imported since, and `allItemIds` is read only when a folder
    /// target is met).
    public static func stillFree(
        _ target: PermanentDeletePurge.Target, rowState: (String) -> PermanentDeletePurge.RowState,
        allItemIds: () throws -> [String], caseSensitiveNames: Bool = false
    ) -> PermanentDeletePurge.RowState {
        if let itemId = target.itemId {
            let own = rowState(itemId)
            if own != .absent { return own }
        }
        guard isSharedFolderRoot(target.root) else { return .absent }
        guard let ids = try? allItemIds() else { return .unknown }
        let key = caseSensitiveNames ? target.relativePath : target.relativePath.lowercased()
        // Both name the folder with `safeComponent` alone.
        let episodeMaps = target.root == episodeMapsRoot || target.root == pdfClipsRoot
        return ids.contains {
            // The writers name a map folder with `safeComponent` alone, so an empty id still writes `unknown`: it counts
            // here, though it never gets a target of its own.
            let name = episodeMaps ? PodcastAnchorEvidencePaths.safeComponent($0) : preparedAudioDirectoryName(itemId: $0)
            return (caseSensitiveNames ? name : name.lowercased()) == key
        } ? .present : .absent
    }

    /// Roots whose folder names are made from the id, so two ids can name one folder.
    public static func isSharedFolderRoot(_ root: String) -> Bool {
        root == preparedAudioRoot || root == episodeMapsRoot || root == pdfClipsRoot
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
    /// The episode-map folder follows the same rule.
    ///
    /// `assets` are the items' ledger rows, read before the delete (`SQLiteSessionStore.loadOwnedOfflineAssets(itemId:)`);
    /// the copied EPUBs and audiobooks they name are added by `copiedSourceTarget`.
    public static func targets(
        forItems itemIds: [String], assets: [OwnedOfflineAsset] = []
    ) -> [PermanentDeletePurge.Target] {
        var targets: [PermanentDeletePurge.Target] = []
        var folders: Set<String> = []
        var mapFolders: Set<String> = []
        var clipFolders: Set<String> = []
        for itemId in itemIds {
            targets.append(.init(
                root: listeningEditionsRoot, relativePath: listeningEditionFileName(itemId: itemId), itemId: itemId))
            let folder = preparedAudioDirectoryName(itemId: itemId)
            if !itemId.isEmpty, folders.insert(folder).inserted {
                targets.append(.init(root: preparedAudioRoot, relativePath: folder, itemId: itemId))
            }
            if let mapFolder = episodeMapDirectoryName(itemId: itemId), mapFolders.insert(mapFolder).inserted {
                targets.append(.init(root: episodeMapsRoot, relativePath: mapFolder, itemId: itemId))
            }
            if let original = itemOriginalsFolderName(itemId: itemId) {
                targets.append(.init(root: itemOriginalsRoot, relativePath: original, itemId: itemId))
            }
            if let clipFolder = pdfClipDirectoryName(itemId: itemId), clipFolders.insert(clipFolder).inserted {
                targets.append(.init(root: pdfClipsRoot, relativePath: clipFolder, itemId: itemId))
            }
            var copied: Set<String> = []
            for asset in assets {
                if let target = copiedSourceTarget(forAsset: asset, ofItem: itemId),
                   copied.insert(target.root + "/" + target.relativePath).inserted {
                    targets.append(target)
                }
            }
        }
        return targets
    }

    public static func targets(forItem itemId: String, assets: [OwnedOfflineAsset] = []) -> [PermanentDeletePurge.Target] {
        targets(forItems: [itemId], assets: assets)
    }
}
