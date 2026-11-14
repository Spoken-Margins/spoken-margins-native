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

    /// Every file the item owns alone. The prepared-audio folder is named from the id by a lossy rule, so it is named
    /// here only when the rule changed nothing for this id (plain ASCII letters, digits and hyphens, at most 80
    /// characters): an id with other characters, or a long one, might share its folder with another id, and is left
    /// for a later pass. For the ids the app makes (a prefix and a UUID) the folder is the item's alone. If a hand-made
    /// id such as `a_b` did share the folder of `a-b`, the loss is rendered narration, which the app renders again;
    /// it is never a recording or a Margin.
    public static func targets(forItem itemId: String) -> [PermanentDeletePurge.Target] {
        var targets = [PermanentDeletePurge.Target(
            root: listeningEditionsRoot, relativePath: listeningEditionFileName(itemId: itemId))]
        let folder = preparedAudioDirectoryName(itemId: itemId)
        if !itemId.isEmpty, folder == itemId, itemId.allSatisfy({ $0.isASCII }) {
            targets.append(.init(root: preparedAudioRoot, relativePath: folder))
        }
        return targets
    }

    public static func targets(forItems itemIds: [String]) -> [PermanentDeletePurge.Target] {
        itemIds.flatMap(targets(forItem:))
    }
}
