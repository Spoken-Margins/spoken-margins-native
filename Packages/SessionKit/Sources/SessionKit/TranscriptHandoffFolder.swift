import Foundation

/// Where the share extension leaves a transcript file for the app (#2997, PR 5b).
///
/// The extension can't import a transcript itself (it doesn't link SessionKit and has a small memory limit), so it
/// copies the file, unread, into the App Group, and the app imports it the next time it comes forward. This is that
/// folder: the extension writes it with `save`, and the app lists it with `pending` and clears an entry with `delete`.
///
/// The share extension compiles this file and `TranscriptImportMessage.swift` directly (project.yml), as it does
/// `SharedTextIntake.swift`, so both stay Foundation-only. Because the layout is SessionKit's, a host test writes
/// and drains it the way the two processes do.
///
/// Layout, inside `<App Group>/TranscriptHandoffs/`:
/// - `<uuid>.<ext>`: the file's exact bytes, `<ext>` being `vtt`, `srt` or `docx`;
/// - `<uuid>.json`: the file's original name, written last, so an entry exists only once its bytes are complete.
///   A half-written entry (a kill between the two writes) has no `.json`, is never drained, and is swept an hour later.
public struct TranscriptHandoffFolder: @unchecked Sendable {
    public static let directoryName = "TranscriptHandoffs"

    /// The files the extension copies. A `.txt` isn't here: it keeps its route as a text payload, and the app asks
    /// whether it is a transcript when it drains it.
    public static let fileExtensions: Set<String> = ["vtt", "srt", "docx"]

    /// The same cap as `TranscriptImport.maximumBytes`; a test keeps them equal, because this file can't read that one.
    public static let maximumBytes = 10_000_000

    /// How long a file with no `.json` beside it, or a half-copied one, stays before it is swept.
    public static let orphanLifetime: TimeInterval = 3_600

    /// One file waiting for the app.
    public struct Entry: Equatable, Sendable {
        public var id: String
        /// The name the file had when it was shared, so the item is titled from it, not from `<uuid>.vtt`.
        public var fileName: String
        public var dataURL: URL
        public var savedAt: Date
    }

    private struct Record: Codable {
        var id: String
        var fileName: String
        var savedAt: Date
    }

    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    /// Whether a file name is one the extension hands off as a transcript file.
    public static func isTranscriptFile(named name: String?) -> Bool {
        guard let name else { return false }
        return fileExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private var directory: URL { baseDirectory.appendingPathComponent(Self.directoryName, isDirectory: true) }

    private func dataURL(id: String, fileExtension: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    private func recordURL(id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    // MARK: The extension's side

    /// Copies a shared file in, unread, and returns the entry's id. `originalName` is the name the share gave it.
    ///
    /// Throws a `TranscriptImportMessage` the extension can show as it is: `.unsupportedType` for any other extension,
    /// `.tooLarge` over the cap, `.couldNotRead` when the provider's file can't be copied. Nothing is left behind on a
    /// failure.
    @discardableResult
    public func save(from sourceURL: URL, originalName: String) throws -> String {
        let name = (originalName as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard Self.fileExtensions.contains(fileExtension) else {
            throw TranscriptImportMessage(.unsupportedType, fileName: name)
        }
        // Security-scoped access exists only on Apple platforms; the host tests on Linux read plain files.
        #if canImport(Darwin)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        #endif
        let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile != false else { throw TranscriptImportMessage(.couldNotRead, fileName: name) }
        if let size = values?.fileSize, size > Self.maximumBytes { throw TranscriptImportMessage(.tooLarge, fileName: name) }

        let id = UUID().uuidString.lowercased()
        let destination = dataURL(id: id, fileExtension: fileExtension)
        let staged = directory.appendingPathComponent(".\(id).staged")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: staged)
            // A copy keeps the source's modification date, and a transcript from last week would look abandoned to the
            // sweep the moment it landed. The sweep reads age from this date, so it is set to now.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: staged.path)
            // The size read before the copy can be missing or stale, so the copy is measured too.
            if let copied = try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize, copied > Self.maximumBytes {
                try? fileManager.removeItem(at: staged)
                throw TranscriptImportMessage(.tooLarge, fileName: name)
            }
            try fileManager.moveItem(at: staged, to: destination)
        } catch let message as TranscriptImportMessage {
            throw message
        } catch {
            try? fileManager.removeItem(at: staged)
            throw TranscriptImportMessage(.couldNotRead, fileName: name)
        }
        do {
            try JSONEncoder().encode(Record(id: id, fileName: name, savedAt: Date())).write(to: recordURL(id: id), options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: destination)
            throw TranscriptImportMessage(.couldNotRead, fileName: name)
        }
        return id
    }

    // MARK: The app's side

    /// The complete entries, oldest first. An entry whose bytes are gone is dropped here (it can never import), and a
    /// `.json` this build can't read is left alone for a later build.
    public func pending() throws -> [Entry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var entries: [Entry] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let record = try? decoder.decode(Record.self, from: data),
                  record.id == url.deletingPathExtension().lastPathComponent else { continue }
            let fileExtension = (record.fileName as NSString).pathExtension.lowercased()
            let dataURL = dataURL(id: record.id, fileExtension: fileExtension)
            guard Self.fileExtensions.contains(fileExtension), fileManager.fileExists(atPath: dataURL.path) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append(Entry(id: record.id, fileName: record.fileName, dataURL: dataURL, savedAt: record.savedAt))
        }
        return entries.sorted { ($0.savedAt, $0.id) < ($1.savedAt, $1.id) }
    }

    /// Removes an entry's bytes and its record. Safe to call twice.
    public func delete(_ entry: Entry) {
        try? fileManager.removeItem(at: entry.dataURL)
        try? fileManager.removeItem(at: recordURL(id: entry.id))
    }

    /// Removes what a killed share left: bytes with no `.json`, and half-copied `.staged` files, once they are older than
    /// `orphanLifetime`. A complete entry is never touched. Returns how many files it removed.
    @discardableResult
    public func sweepOrphans(now: Date = Date()) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let records = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
        var removed = 0
        for name in names where !name.hasSuffix(".json") {
            let stem = name.hasPrefix(".") ? String(name.dropFirst()) : name
            let id = stem.split(separator: ".", maxSplits: 1).first.map(String.init) ?? stem
            guard name.hasSuffix(".staged") || !records.contains(id) else { continue }
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) > Self.orphanLifetime else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
