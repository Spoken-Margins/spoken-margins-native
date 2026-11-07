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
    ///
    /// The names are found inside SQLite, so a payload (megabytes for a layer with a shared map) never crosses into
    /// Swift (#3410). `json_tree` walks the strings and keys of a payload, and only the ones holding a UUID-shaped
    /// run come back, so the regex runs on a few short strings. That is the names the sweep's
    /// `importedCommentaryRecordsMentioning` finds by running the regex over the whole stored text, whatever field
    /// names a payload uses (a row from a newer build is quarantined with fields this build doesn't know), because a
    /// UUID-shaped run holds only hex digits and hyphens and so never spans two JSON strings.
    ///
    /// Three things are not looked at, and each can only leave a folder for the launch sweep, never remove one in
    /// use (the sweep's own check decides every removal):
    /// - the bulk artifact fields (`bulkFields`: a shared map's proposals and sketches, up to 5 MB), cut out before
    ///   the walk, because they hold no path;
    /// - a string over `maxStringBytes` (free text such as a transcript);
    /// - a row that isn't valid JSON has no tree, so it is read whole, as before.
    ///
    /// The one difference the other way: a name spelled with a JSON escape (`\u0041`) is found here, because the walk
    /// decodes strings, and not by the sweep, which reads the raw text.
    public static func candidateFolderNames(ofItems itemIds: [String], store: SQLiteSessionStore) throws -> Set<String> {
        var names: Set<String> = []
        let layerIdsOfItem = """
            SELECT id FROM records WHERE kind = 'imported_commentary_layer' AND item_id = ?1
            UNION SELECT id FROM quarantined_records WHERE kind = 'imported_commentary_layer'
              AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.itemId') END = ?1
            """
        let sources = [
            """
            records WHERE kind IN ('imported_commentary_layer', 'imported_commentary_interjection') AND item_id = ?1
            """,
            """
            quarantined_records
            WHERE (kind = 'imported_commentary_layer'
                   AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.itemId') END = ?1)
               OR (kind = 'imported_commentary_interjection'
                   AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.layerId') END IN (\(layerIdsOfItem)))
            """,
        ]
        func collect(_ text: String) {
            for match in uuidShape.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { names.insert(String(text[range])) }
            }
        }
        for id in Set(itemIds) {
            for source in sources {
                try store.readTexts(
                    """
                    SELECT CASE WHEN typeof(j.key) = 'text' AND octet_length(j.key) <= \(maxStringBytes) AND j.key GLOB '\(uuidPrefilter)' THEN j.key || ' ' ELSE '' END
                         || CASE WHEN j.type = 'text' AND octet_length(j.atom) <= \(maxStringBytes) AND j.atom GLOB '\(uuidPrefilter)' THEN j.atom ELSE '' END
                    FROM (SELECT payload FROM \(source)) AS r,
                         json_tree(CASE WHEN json_valid(r.payload) THEN json_remove(r.payload, \(bulkFields)) ELSE '[]' END) AS j
                    WHERE (typeof(j.key) = 'text' AND octet_length(j.key) <= \(maxStringBytes) AND j.key GLOB '\(uuidPrefilter)')
                       OR (j.type = 'text' AND octet_length(j.atom) <= \(maxStringBytes) AND j.atom GLOB '\(uuidPrefilter)');
                    """,
                    [id], name: "friend_packet_folder_candidates", collect)
                try store.readTexts(
                    "SELECT payload FROM (SELECT payload FROM \(source)) WHERE NOT json_valid(payload);",
                    [id], name: "friend_packet_folder_candidates_unparsed", collect)
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

    /// A cheap SQL test that a string might hold a UUID-shaped run: eight hex digits, a hyphen, four hex digits and a
    /// hyphen. Every real match passes it, so it only decides which strings the regex looks at.
    /// A path or a key is never this long. Free text (a transcript, a shared map's words) is, and `GLOB` over
    /// megabytes of it costs seconds, so a string above this is not looked at. A folder named only inside such
    /// text is not a candidate now; nothing removes it, and the launch sweep takes it once no row names it.
    private static let maxStringBytes = 2048

    /// Fields of an imported layer that carry a shared map's artifacts: arrays of hashes and windows, never a path.
    private static let bulkFields = "'$.listeningMapProposals', '$.editionFingerprintSpines', '$.transcriptPhraseSketches'"

    private static let uuidPrefilter: String = {
        let hex = "[0-9A-Fa-f]"
        return "*" + String(repeating: hex, count: 8) + "-" + String(repeating: hex, count: 4) + "-*"
    }()

    private static let uuidShape = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
}
