import Foundation

/// Where a Shortcuts action leaves a link list for the app to add the next time it opens (#4683, Design section 2g).
///
/// "Add Link List to Spoken Margins" runs without opening the app (`openAppWhenRun = false`), so it can't import: it
/// checks the list, saves it here, and the app drains the folder when it next comes forward. The app passes the folder's
/// base URL in (the app-group folder beside the share extension's `SourceLinkHandoffs/`); SessionKit knows no app group.
///
/// Layout, inside `<base>/LinkListHandoffs/`: one file per list, named
/// `<UTC yyyyMMdd'T'HHmmss'Z'>-<uuid>.json`, which also sets the order (oldest first). The file holds the list's JSON
/// object. At most `maxFiles` wait at once, each at most `maxFileBytes`.
///
/// Entries the list had to skip (not https, no url) are not stored: the Shortcut's own dialog and the arrival's banner
/// work from the links that remain. Follow flags are kept.
///
/// The Shortcuts action (`LinkListShortcutAction`) writes here; the app's `drainLinkListHandoffs()` reads and removes.
public struct LinkListHandoffFolder: @unchecked Sendable {
    public static let directoryName = "LinkListHandoffs"
    /// At most this many lists wait; the next write throws `.full`.
    public static let maxFiles = 20
    /// The same cap as `LinkListFile.maxFileBytes`, so a saved list is always one the reader will take.
    public static let maxFileBytes = 1_000_000

    /// How the Shortcut's save can fail. `message` is what the Shortcut tells the listener.
    public enum SaveError: Error, Equatable, Sendable, LocalizedError {
        case full
        case tooLarge
        case couldNotWrite

        public var message: String {
            switch self {
            case .full: return "Spoken Margins already has \(LinkListHandoffFolder.maxFiles) lists waiting. Open the app to add them first."
            case .tooLarge: return LinkListFile.tooLargeMessage
            case .couldNotWrite: return "Spoken Margins couldn't save this list. Try again."
            }
        }

        public var errorDescription: String? { message }
    }

    /// One saved list waiting for the app.
    public struct Entry: Equatable, Sendable {
        /// The file's name, which is also its key in `LinkListRetryLedger`.
        public var id: String
        public var url: URL
    }

    /// Writes bytes to a URL with options. Injected so a host test can read back the file-protection option the app
    /// passes; the default is `Data.write(to:options:)`.
    public typealias Writer = @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    /// Written atomically (a reader never sees half a file), readable after the first unlock so a locked phone's
    /// Shortcut still saves.
    public static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let writer: Writer
    private let now: @Sendable () -> Date

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        writer: @escaping Writer = { data, url, options in try data.write(to: url, options: options) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.writer = writer
        self.now = now
    }

    private var directory: URL { baseDirectory.appendingPathComponent(Self.directoryName, isDirectory: true) }

    // MARK: The Shortcut's side

    /// Saves a list and returns its entry. Throws `.full` when `maxFiles` already wait, `.tooLarge` over
    /// `maxFileBytes`, `.couldNotWrite` for any other failure; nothing is left behind on a failure.
    @discardableResult
    public func save(_ list: LinkListFile) throws -> Entry {
        let data = try Self.encode(list)
        guard data.count <= Self.maxFileBytes else { throw SaveError.tooLarge }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SaveError.couldNotWrite
        }
        // An unreadable folder (permissions, a plain file in its place) is a failed save, not a raw system error.
        guard let waiting = try? listedNames() else { throw SaveError.couldNotWrite }
        // A soft cap: two Shortcut runs in the same instant can both see 19 and leave 21. The drain takes them all.
        guard waiting.count < Self.maxFiles else { throw SaveError.full }

        // Two lists saved in the same UTC second sort by their random uuid, so "oldest first" holds per second.
        let name = Self.fileName(date: now(), id: UUID())
        let url = directory.appendingPathComponent(name)
        do {
            try writer(data, url, Self.writingOptions)
        } catch {
            try? fileManager.removeItem(at: url)
            throw SaveError.couldNotWrite
        }
        return Entry(id: name, url: url)
    }

    // MARK: The app's side

    /// The saved lists, oldest first. A file whose name isn't this folder's pattern is left alone and not listed.
    public func pending() -> [Entry] {
        ((try? listedNames()) ?? []).map { Entry(id: $0, url: directory.appendingPathComponent($0)) }
    }

    /// The list in an entry's file: `.linkList` when it reads, `.rejected` with the listener's message when the file
    /// is over the size cap or can't be read as a list, and `.notALinkList` for a file that is gone or not a list. The
    /// caller removes an unreadable file at once.
    public func read(_ entry: Entry) -> LinkListFile.Recognition {
        let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        if let size, size > Self.maxFileBytes { return .rejected(LinkListFile.tooLargeMessage) }
        guard let data = try? Data(contentsOf: entry.url) else { return .notALinkList }
        return LinkListFile.recognize(data)
    }

    /// Removes an entry's file. Safe to call twice.
    public func remove(_ entry: Entry) {
        try? fileManager.removeItem(at: entry.url)
    }

    // MARK: Names and bytes

    /// The names in the folder that match `<yyyyMMdd'T'HHmmss'Z'>-<uuid>.json`, oldest first (a plain sort of the name).
    private func listedNames() throws -> [String] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        return names.filter(Self.isHandoffName).sorted()
    }

    static func fileName(date: Date, id: UUID) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "\(stamp)-\(id.uuidString.lowercased()).json"
    }

    static func isHandoffName(_ name: String) -> Bool {
        // 8 digits, "T", 6 digits, "Z", "-", a 36-character uuid, ".json".
        let pattern = #"^\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// The list as the JSON object `LinkListFile.recognize` reads back: `schemaVersion`, `title` when there is one, and
    /// `entries` in order, each with `url`, `title` when there is one, and `"follow": true` only for a follow.
    static func encode(_ list: LinkListFile) throws -> Data {
        var object: [String: Any] = ["schemaVersion": LinkListFile.schemaVersion]
        if let title = list.title, !title.isEmpty { object["title"] = title }
        object["entries"] = list.entries.map { entry -> [String: Any] in
            var fields: [String: Any] = ["url": entry.url]
            if let title = entry.title, !title.isEmpty { fields["title"] = title }
            if entry.follow { fields["follow"] = true }
            return fields
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw SaveError.couldNotWrite
        }
    }
}
