import Foundation

/// One named place Margins are delivered as Markdown notes: a folder plus what goes into it (#492).
///
/// Before this, Margin Output had exactly one folder, kept as a bookmark in UserDefaults next to one on/off flag
/// and one destination ID. A destination keeps those together so a listener can have several ("Obsidian vault",
/// "Work notes"), each with its own scope and note contents.
///
/// `id` is also the key the delivery journal files its entries under, so it must never change once notes have been
/// written: a new id makes delivery treat the folder as new and rewrite every note. Renaming, pausing and changing
/// what is included leave it alone. Re-granting access to a folder, or pointing the destination at another one, keeps the
/// id too: notes missing from the new folder are simply written, and the writer never replaces a file it didn't write.
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
    /// Whether each note carries the passage around its Margin (the "Context before" and "Context after" sections).
    /// The title, source link and position stay either way: a note that can't say where it came from is no use.
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

    /// A missing field takes today's single-folder behavior. A field that is present but unreadable (a newer build
    /// wrote a value this build doesn't know) is not guessed at: the destination loads paused, so it never delivers
    /// more than the listener allowed. Unpausing it is the listener's choice.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        var unreadable = false
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do { return try container.decodeIfPresent(T.self, forKey: key) ?? fallback }
            catch { unreadable = true; return fallback }
        }
        scope = value(.scope, default: Scope.all)
        includesContext = value(.includesContext, default: true)
        text = value(.text, default: TextChoice.cleaned)
        isEnabled = value(.isEnabled, default: true)
        if unreadable { isEnabled = false }
    }

    /// What this destination's notes hold.
    public var content: MarginNoteContent {
        MarginNoteContent(scope: scope, includesContext: includesContext, text: text)
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

/// What goes into the notes for one destination: which Margins, and what each note carries. `standard` is what the
/// single notes folder always wrote, so a destination left at its defaults produces byte-identical notes and the
/// writer rewrites nothing.
public struct MarginNoteContent: Equatable, Sendable {
    public var scope: MarginOutputDestination.Scope
    public var includesContext: Bool
    public var text: MarginOutputDestination.TextChoice

    public init(scope: MarginOutputDestination.Scope = .all, includesContext: Bool = true, text: MarginOutputDestination.TextChoice = .cleaned) {
        self.scope = scope
        self.includesContext = includesContext
        self.text = text
    }

    public static let standard = MarginNoteContent()
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
        private struct Skipped: Decodable {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            // One destination this build can't read (no id or bookmark, say) must not take the others with it.
            // It is skipped here, so a save by this build no longer carries it.
            var elements = try container.nestedUnkeyedContainer(forKey: .destinations)
            var readable: [MarginOutputDestination] = []
            while !elements.isAtEnd {
                if let destination = try? elements.decode(MarginOutputDestination.self) { readable.append(destination) }
                else { _ = try? elements.decode(Skipped.self) }
            }
            destinations = readable
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
        /// `marginOutputDestinationID`; nil on a build that never wrote one.
        public var destinationID: String?
        /// `automaticMarginOutputEnabled`.
        public var isEnabled: Bool

        public init(bookmark: Data?, destinationID: String?, isEnabled: Bool) {
            self.bookmark = bookmark
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
    ///
    /// Call it after `SavedFolderSetting.separateMarginNotesFromSessionExport()`: before that runs, a pre-#930
    /// install has no notes bookmark yet, and an empty list saved now would never pick up its folder. The app must
    /// also use `fallbackDestinationID` for the journal key wherever it still falls back, and save a refreshed
    /// bookmark back to the store when it resolves a stale one.
    public static func loadOrMigrate(store: MarginOutputDestinationStore, legacy: () -> LegacySettings) throws -> [MarginOutputDestination] {
        if let saved = try store.load() { return saved }
        let migrated = destinations(from: legacy())
        try store.save(migrated)
        return migrated
    }
}
