import Foundation
import SessionKit

/// Takes a friend's imported recording off the phone when the listener deletes an item for good (#3406).
///
/// Importing a packet keeps `IncomingPackages/<uuid>/` (the friend's audio and the packet) for good, and the
/// imported Margins play from it. Permanent delete removed the item's rows but left that folder for the next
/// launch's sweep. This removes the folders at the delete, and only those: the ones the item's own imported layers
/// and Margins named, and only if no remaining row names them. It is `IncomingPackageSweep` with `only:` set to
/// that list, never a sweep of the whole directory, so another item's folder and a packet being imported (its
/// folder is in `keeping`, and is named by no row yet) stay. It never touches `SpokenMargins/` recordings, the
/// listener's own voice, or any other folder.
public enum FriendPacketFolders {
    /// The UUID-shaped names in the stored JSON of the item's imported layers and Margins, live and quarantined.
    /// A name here is only a candidate: most are ids, and the sweep keeps anything that is not a folder.
    public static func candidateFolderNames(ofItems itemIds: [String], store: SQLiteSessionStore) throws -> Set<String> {
        var names: Set<String> = []
        let layerIdsOfItem = """
            SELECT id FROM records WHERE kind = 'imported_commentary_layer' AND item_id = ?1
            UNION SELECT id FROM quarantined_records WHERE kind = 'imported_commentary_layer'
              AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.itemId') END = ?1
            """
        let queries = [
            """
            SELECT payload FROM records
            WHERE kind IN ('imported_commentary_layer', 'imported_commentary_interjection') AND item_id = ?1;
            """,
            """
            SELECT payload FROM quarantined_records
            WHERE (kind = 'imported_commentary_layer'
                   AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.itemId') END = ?1)
               OR (kind = 'imported_commentary_interjection'
                   AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.layerId') END IN (\(layerIdsOfItem)));
            """,
        ]
        for id in Set(itemIds) {
            for sql in queries {
                try store.readTexts(sql, [id], name: "friend_packet_folder_candidates") { payload in
                    for match in uuidShape.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)) {
                        if let range = Range(match.range, in: payload) { names.insert(String(payload[range])) }
                    }
                }
            }
        }
        return names
    }

    /// Runs `delete` (the call that removes the items' rows), then removes the friend's packet folders those rows
    /// named, off the calling thread. The names are read before `delete` and the files are removed only after it
    /// returns, so a failed delete leaves every file in place and no row is left pointing at nothing. If the names
    /// can't be read, the delete still goes ahead and the launch sweep removes the folders later.
    ///
    /// `beforeRemovingFile` is called with each file of a folder about to go, so derived copies keyed to the file's
    /// content (the leveled playback copy of a friend's voice) can be removed while the file can still be read.
    /// The order is the row delete, then those copies, then the folder.
    ///
    /// The returned task finishes when the removal does; callers need not wait for it.
    @discardableResult
    public static func deleting(
        itemIds: [String],
        store: SQLiteSessionStore,
        directory: URL,
        keeping: Set<String>,
        beforeRemovingFile: @escaping @Sendable (URL) -> Void = { _ in },
        delete: () throws -> Void
    ) throws -> Task<IncomingPackageSweep.Outcome, Never> {
        let candidates = (try? candidateFolderNames(ofItems: itemIds, store: store)) ?? []
        try delete()
        guard !candidates.isEmpty else { return Task { IncomingPackageSweep.Outcome() } }
        return Task.detached(priority: .utility) {
            IncomingPackageSweep.sweep(
                directory: directory, keeping: keeping, only: candidates, store: store,
                beforeRemoving: beforeRemovingFile)
        }
    }

    private static let uuidShape = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
}
