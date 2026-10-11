import Foundation

/// One named place Margins are delivered as Markdown notes: a folder plus what goes into it (#492).
///
/// Before this, Margin Output had exactly one folder, kept as a bookmark in UserDefaults next to one on/off flag
/// and one destination ID. A destination keeps those together so a listener can have several ("Obsidian vault",
/// "Work notes"), each with its own scope and note contents.
///
/// `id` is also the key the delivery journal files its entries under, so it must never change once notes have been
/// written: a new id makes delivery treat the folder as new and rewrite every note. Renaming, pausing and changing
/// what is included leave it alone. Picking a different folder is the caller's choice (it keeps the id when the
/// listener is only re-granting access to the same folder, and takes a new one for a different folder).
public struct MarginOutputDestination: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        /// Every Margin.
        case all
        /// Only starred Margins.
        case starred
    }

    public enum TextChoice: String, Codable, CaseIterable, Sendable {
        /// The cleaned-up transcript, falling back to the original when there is none.
        case cleaned
        /// The transcript as it was recognized.
        case original
    }

    public var id: String
    /// What the listener calls it. Shown in Settings and in status lines.
    public var name: String
    /// A security-scoped bookmark for the folder. Opaque here; the app creates and resolves it.
    public var bookmark: Data
    public var scope: Scope
    /// Whether each note carries its source context (reference, anchor and title).
    public var includesContext: Bool
    public var text: TextChoice
    /// False while paused: nothing is delivered, but the folder, settings and journal stay.
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        bookmark: Data,
        scope: Scope = .all,
        includesContext: Bool = true,
        text: TextChoice = .cleaned,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.scope = scope
        self.includesContext = includesContext
        self.text = text
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bookmark, scope, includesContext, text, isEnabled
    }

    /// A file written by a newer build may hold a value this build doesn't know; that field falls back to today's
    /// behavior rather than losing the whole destination.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        scope = (try? container.decodeIfPresent(Scope.self, forKey: .scope)) ?? .all
        includesContext = (try? container.decodeIfPresent(Bool.self, forKey: .includesContext)) ?? true
        text = (try? container.decodeIfPresent(TextChoice.self, forKey: .text)) ?? .cleaned
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }

    /// The name for the next destination the listener adds, e.g. "Notes folder 2".
    public static func nextName(base: String = MarginOutputMigration.migratedName, existing: [MarginOutputDestination]) -> String {
        let taken = Set(existing.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

/// The destinations as one JSON file in Application Support. It stays out of the database so the previous build
/// can still open the database unchanged.
public struct MarginOutputDestinationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenMargins/MarginOutputDestinations.json")
    }

    private struct FileContents: Codable {
        var version = 1
        var destinations: [MarginOutputDestination]

        init(destinations: [MarginOutputDestination]) { self.destinations = destinations }

        private enum CodingKeys: String, CodingKey { case version, destinations }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            destinations = try container.decode([MarginOutputDestination].self, forKey: .destinations)
        }
    }

    /// The saved destinations, in the order the listener sees them. Nil when nothing was ever saved (the caller may
    /// migrate then); an empty list means the listener removed them all, which migration must not undo. A file that
    /// exists but can't be read throws, so it is never replaced by a guess.
    public func load() throws -> [MarginOutputDestination]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL)).destinations
    }

    public func save(_ destinations: [MarginOutputDestination]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(FileContents(destinations: destinations)).write(to: fileURL, options: .atomic)
    }
}

/// Turns today's single notes folder into the first destination.
public enum MarginOutputMigration {
    /// What the old single-folder setup kept in UserDefaults.
    public struct LegacySettings: Equatable, Sendable {
        /// `marginNotesFolderBookmark`; nil when no folder was ever chosen.
        public var bookmark: Data?
        /// `marginNotesFolderName`: the folder's name, used when the bookmark can't give one.
        public var folderName: String?
        /// `marginOutputDestinationID`; nil on a build that never wrote one.
        public var destinationID: String?
        /// `automaticMarginOutputEnabled`.
        public var isEnabled: Bool

        public init(bookmark: Data?, folderName: String?, destinationID: String?, isEnabled: Bool) {
            self.bookmark = bookmark
            self.folderName = folderName
            self.destinationID = destinationID
            self.isEnabled = isEnabled
        }
    }

    public static let migratedName = "Notes folder"
    /// What the old code used for the journal key when it had no stored destination ID.
    public static let fallbackDestinationID = "initial"

    /// The one destination today's settings amount to, or none when there was no folder. It keeps the old
    /// destination ID and bookmark, so it writes to the same files and the journal still recognizes them: no note
    /// is rewritten or duplicated. Scope, context and text match what the single folder always wrote.
    public static func destinations(from legacy: LegacySettings) -> [MarginOutputDestination] {
        guard let bookmark = legacy.bookmark, !bookmark.isEmpty else { return [] }
        return [MarginOutputDestination(
            id: legacy.destinationID ?? fallbackDestinationID,
            name: migratedName,
            bookmark: bookmark,
            scope: .all,
            includesContext: true,
            text: .cleaned,
            isEnabled: legacy.isEnabled
        )]
    }

    /// The saved destinations, migrating the old single folder the first time. The migrated list is saved at once,
    /// so a later change to the old keys (or removing every destination) is never migrated again. The old keys are
    /// left in place for the previous build.
    public static func loadOrMigrate(store: MarginOutputDestinationStore, legacy: () -> LegacySettings) throws -> [MarginOutputDestination] {
        if let saved = try store.load() { return saved }
        let migrated = destinations(from: legacy())
        try store.save(migrated)
        return migrated
    }
}
