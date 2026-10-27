import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// True when any imported layer or imported Margin, live or quarantined, names `needle` anywhere in its stored
    /// JSON. Imported Margins keep their voice (`audioPath`), podcast evidence and episode-map files in the
    /// folder a packet was extracted to, so the folder's name is enough to tell whether they still use it. It
    /// reads the stored text, not the decoded values, so a row this build can't decode still counts, and it fails
    /// closed: a database error throws, never reads as "not used".
    public func importedCommentaryRecordsMention(_ needle: String) throws -> Bool {
        guard !needle.isEmpty else { return true }
        for table in ["records", "quarantined_records"] {
            var found = false
            try readTexts(
                """
                SELECT 'used' FROM \(table)
                WHERE kind IN ('imported_commentary_layer', 'imported_commentary_interjection')
                AND instr(payload, ?1) > 0 LIMIT 1;
                """,
                [needle], name: "imported_commentary_mentions"
            ) { _ in found = true }
            if found { return true }
        }
        return false
    }
}

extension SQLiteSessionStore {
    /// Which of `folderNames` (UUID-shaped names) any imported layer or imported Margin, live or quarantined, names
    /// anywhere in its stored JSON: `importedCommentaryRecordsMention` for many names in one pass over the rows
    /// instead of one scan of every payload per name (#2246). A payload is read once and the UUID-shaped runs in it
    /// are checked against the names, which finds exactly the names a substring search would, since a UUID's
    /// hyphens fix where another UUID could start. A name that is not UUID-shaped is reported as used, so the
    /// caller keeps it. Like the single-name check it reads the stored text, not decoded values, and a database
    /// error throws: never "not used".
    public func importedCommentaryRecordsMentioning(among folderNames: Set<String>) throws -> Set<String> {
        var used = folderNames.filter { UUID(uuidString: $0) == nil }
        var remaining = folderNames.subtracting(used)
        guard !remaining.isEmpty else { return used }
        for table in ["records", "quarantined_records"] {
            try readTexts(
                "SELECT payload FROM \(table) WHERE kind IN ('imported_commentary_layer', 'imported_commentary_interjection');",
                [], name: "imported_commentary_mentions_batch"
            ) { payload in
                guard !remaining.isEmpty else { return }
                for match in Self.uuidShape.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)) {
                    guard let range = Range(match.range, in: payload) else { continue }
                    let name = String(payload[range])
                    if remaining.remove(name) != nil { used.insert(name) }
                }
            }
            if remaining.isEmpty { break }
        }
        return used
    }

    private static let uuidShape = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
}

/// Removes the working folders of shared packets that nothing uses (#2154).
///
/// Staging a packet extracts it to `IncomingPackages/<uuid>/`. Import keeps that folder for good, because the
/// imported Margins play from it; Cancel and a failed stage remove it. An app killed while a review shows is
/// neither, and the packet reopens on the next launch into a fresh folder, so each kill left one more copy.
/// This runs at launch, before anything is staged, and removes only a folder that is not in `keeping` (a review
/// that is showing or waiting, a restore in flight) and that no imported layer or Margin names. It is never a
/// sweep by age: a folder a Margin uses stays however old it is.
public enum IncomingPackageSweep {
    public struct Outcome: Equatable, Sendable {
        public var removed: [String] = []
        /// Folders that stayed because a review owns them or an imported Margin uses them, or because the check or
        /// the removal failed (nothing is removed on a guess).
        public var kept: [String] = []

        public init() {}
    }

    /// `directory` is `Application Support/SpokenMargins/IncomingPackages`. Only sub-folders named like a UUID are
    /// looked at; anything else is left alone. With `only`, a folder not in that set is left alone too: a sweep
    /// that runs in the background passes the folders it listed before deciding what is owned, so a folder staged
    /// meanwhile (which no one has marked as owned yet) is never a candidate.
    @discardableResult
    public static func sweep(
        directory: URL,
        keeping: Set<String>,
        only: Set<String>? = nil,
        isUsed: (String) throws -> Bool,
        fileManager: FileManager = .default
    ) -> Outcome {
        var outcome = Outcome()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return outcome }
        for name in names.sorted() where UUID(uuidString: name) != nil && only?.contains(name) ?? true {
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            let attributes = try? fileManager.attributesOfItem(atPath: folder.path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
            guard !keeping.contains(name), (try? isUsed(name)) == false else {
                outcome.kept.append(name)
                continue
            }
            do {
                try fileManager.removeItem(at: folder)
                outcome.removed.append(name)
            } catch {
                outcome.kept.append(name)
            }
        }
        return outcome
    }

    /// The same sweep with the Library deciding what is used, from one read of the imported payloads however many
    /// folders there are (#2246). A folder that appeared after the listing, or a failed read, keeps its folder.
    @discardableResult
    public static func sweep(
        directory: URL, keeping: Set<String>, only: Set<String>? = nil, store: SQLiteSessionStore,
        fileManager: FileManager = .default
    ) -> Outcome {
        let candidates = Set(folderNames(in: directory, fileManager: fileManager)
            .filter { !keeping.contains($0) && (only?.contains($0) ?? true) })
        let used = try? store.importedCommentaryRecordsMentioning(among: candidates)
        struct Unreadable: Error {}
        return sweep(directory: directory, keeping: keeping, only: only, isUsed: { name in
            guard let used, candidates.contains(name) else { throw Unreadable() }
            return used.contains(name)
        }, fileManager: fileManager)
    }

    /// The UUID-named sub-folders of `directory`.
    static func folderNames(in directory: URL, fileManager: FileManager) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().filter { name in
            guard UUID(uuidString: name) != nil else { return false }
            let attributes = try? fileManager.attributesOfItem(atPath: directory.appending(path: name).path)
            return attributes?[.type] as? FileAttributeType == .typeDirectory
        }
    }
}
