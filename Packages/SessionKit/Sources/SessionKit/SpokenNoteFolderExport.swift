import Foundation

/// What the writer remembers about one note in one destination's folder (#3661).
///
/// The first name a note was saved under stays, so a rename later (#3663) rewrites the same files instead of adding a
/// second copy, and a second tap never adds one either. The signature, size and digest say what this app last wrote,
/// so a file the listener changed or replaced is told apart from one that is only out of date.
public struct SpokenNoteFolderEntry: Codable, Equatable, Sendable {
    public var baseName: String
    /// The destination's name as the listener sees it, for the line on the note's row.
    public var folderName: String
    public var audioFileName: String?
    public var transcriptFileName: String?
    /// The takes the saved audio was made from.
    public var audioSignature: String?
    public var audioBytes: Int?
    public var transcriptDigest: String?
}

/// Writes a finished note's audio and transcript into a folder the listener chose (#3661, part of #3658): the folder a
/// Notes Folder destination (#492) points at, reached the way its Margin notes are (the security-scoped folder, file
/// coordination, a journal under Application Support). The files themselves are made by `SpokenNoteExport` (#3660).
///
/// Only ever adds. A name already taken in the folder by something this app did not write is never used: the note gets
/// "<title> 2" instead. A file this app wrote is replaced only while it is still exactly what the app left there; one
/// the listener edited or replaced is left alone and counted.
public actor SpokenNoteFolderWriter {
    public struct Result: Equatable, Sendable {
        /// Files added or brought up to date.
        public var written: [String] = []
        /// Files already there as this app left them.
        public var upToDate: [String] = []
        /// Files the listener changed, left as they are.
        public var keptEdits: [String] = []
        public var baseName = ""
    }

    public enum WriteError: Error, Equatable, LocalizedError {
        case couldNotWrite(String)
        public var errorDescription: String? {
            switch self { case .couldNotWrite(let detail): return detail }
        }
    }

    let journalURL: URL

    public init(journalURL: URL) { self.journalURL = journalURL }

    /// `audioSignature` names the takes the files were made from (their ids), so a note with a new take is rewritten and
    /// one that has not changed is not.
    public func deliver(
        _ files: SpokenNoteExportFiles,
        noteId: String,
        to folder: URL,
        destinationID: String,
        destinationName: String,
        audioSignature: String
    ) throws -> Result {
        let fileManager = FileManager.default
        let key = SpokenNoteFolderJournal.key(destinationID: destinationID, noteId: noteId)
        var journal = try SpokenNoteFolderJournal.load(from: journalURL)
        let granted = AutomaticMarginWriter.beginAccess(to: folder)
        defer { if granted { AutomaticMarginWriter.endAccess(to: folder) } }

        var entry: SpokenNoteFolderEntry
        if var known = journal[key] {
            known.folderName = destinationName
            entry = known
        } else {
            let wanted = (files.audioURL ?? files.transcriptURL)?.deletingPathExtension().lastPathComponent ?? SpokenNoteItem.defaultTitle
            let extensions = [files.audioURL?.pathExtension, files.transcriptURL == nil ? nil : "txt"].compactMap { $0 }
            // Reserved before anything is written, so a copy cut short is never mistaken for a file of the listener's.
            entry = SpokenNoteFolderEntry(
                baseName: Self.freeBaseName(wanted, extensions: extensions, in: folder, fileManager: fileManager),
                folderName: destinationName)
        }
        journal[key] = entry
        try SpokenNoteFolderJournal.save(journal, to: journalURL)

        var result = Result(baseName: entry.baseName)
        var failures: [String] = []

        if let source = files.audioURL {
            let name = entry.audioFileName ?? "\(entry.baseName).\(source.pathExtension)"
            let destination = folder.appendingPathComponent(name)
            let newBytes = Self.byteCount(of: source)
            let existingBytes = Self.byteCount(of: destination)
            enum Action { case write, upToDate, keep }
            let action: Action
            if existingBytes == nil {
                action = .write
            } else if entry.audioSignature == audioSignature, existingBytes == entry.audioBytes {
                action = .upToDate
            } else if entry.audioSignature == nil {
                // Reserved but never recorded as written: only a file the size of this one is taken as the app's own.
                action = existingBytes == newBytes ? .upToDate : .keep
            } else {
                action = existingBytes == entry.audioBytes ? .write : .keep
            }
            switch action {
            case .write:
                if let failure = Self.copy(source, to: destination) { failures.append("\(name): \(failure)") } else {
                    entry.audioFileName = name; entry.audioSignature = audioSignature; entry.audioBytes = newBytes
                    result.written.append(name)
                }
            case .upToDate:
                entry.audioFileName = name; entry.audioSignature = audioSignature; entry.audioBytes = existingBytes
                result.upToDate.append(name)
            case .keep:
                entry.audioFileName = name
                result.keptEdits.append(name)
            }
            journal[key] = entry
            try SpokenNoteFolderJournal.save(journal, to: journalURL)
        }

        if let source = files.transcriptURL {
            let name = entry.transcriptFileName ?? "\(entry.baseName).txt"
            let destination = folder.appendingPathComponent(name)
            let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
            let newDigest = ListeningEdition.digest(text)
            let existing = fileManager.fileExists(atPath: destination.path)
                ? (try? String(contentsOf: destination, encoding: .utf8)).map(ListeningEdition.digest) : nil
            if fileManager.fileExists(atPath: destination.path), existing == nil {
                // Present but unreadable as text: not ours to replace.
                entry.transcriptFileName = name
                result.keptEdits.append(name)
            } else if existing == newDigest {
                entry.transcriptFileName = name; entry.transcriptDigest = newDigest
                result.upToDate.append(name)
            } else if existing == nil || existing == entry.transcriptDigest {
                if let failure = Self.copy(source, to: destination) { failures.append("\(name): \(failure)") } else {
                    entry.transcriptFileName = name; entry.transcriptDigest = newDigest
                    result.written.append(name)
                }
            } else {
                entry.transcriptFileName = name
                result.keptEdits.append(name)
            }
            journal[key] = entry
            try SpokenNoteFolderJournal.save(journal, to: journalURL)
        }

        if !failures.isEmpty { throw WriteError.couldNotWrite(failures.joined(separator: "; ")) }
        return result
    }

    /// "<wanted>", or "<wanted> 2", "<wanted> 3"... — the first name for which no file of any kind exists yet.
    static func freeBaseName(_ wanted: String, extensions: [String], in folder: URL, fileManager: FileManager) -> String {
        func isFree(_ base: String) -> Bool {
            !extensions.contains { fileManager.fileExists(atPath: folder.appendingPathComponent("\(base).\($0)").path) }
        }
        if isFree(wanted) { return wanted }
        var number = 2
        while !isFree("\(wanted) \(number)") { number += 1 }
        return "\(wanted) \(number)"
    }

    private static func byteCount(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Copies `source` to `destination` through a hidden file beside it, so a folder that goes away or fills up mid-copy
    /// never leaves half a file under the real name. Returns a plain reason on failure.
    private static func copy(_ source: URL, to destination: URL) -> String? {
        var failure: String?
        let coordinationError = AutomaticMarginWriter.coordinateWriting(at: destination) { coordinated in
            let fileManager = FileManager.default
            let temporary = coordinated.deletingLastPathComponent()
                .appendingPathComponent(".\(coordinated.lastPathComponent).\(UUID().uuidString).partial")
            do {
                try fileManager.copyItem(at: source, to: temporary)
                // rename(2) puts the finished file under its name in one step, replacing an older copy of ours if there is
                // one. (`replaceItemAt` is not reliable in the Linux Foundation the host tests run on.)
                guard rename(temporary.path, coordinated.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                failure = error.localizedDescription
            }
        }
        return coordinationError?.localizedDescription ?? failure
    }
}

/// The writer's journal: one JSON file in Application Support, beside the Margin notes' one, never in the database.
public enum SpokenNoteFolderJournal {
    /// Keyed by destination and note, like the Margin notes' journal, so each folder keeps its own names.
    public static func key(destinationID: String, noteId: String) -> String {
        destinationID + ":" + ListeningEdition.digest(noteId)
    }

    public static func load(from url: URL) throws -> [String: SpokenNoteFolderEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: SpokenNoteFolderEntry].self, from: Data(contentsOf: url))
    }

    static func save(_ journal: [String: SpokenNoteFolderEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }

    /// The key a note has in `savedFolders(from:)`.
    public static func noteKey(_ noteId: String) -> String { ListeningEdition.digest(noteId) }

    /// For each note (by `noteKey`), the folders it was saved to, by their names. A journal that can't be read says
    /// nothing: the row simply doesn't show the line.
    public static func savedFolders(from url: URL) -> [String: [String]] {
        guard let journal = try? load(from: url) else { return [:] }
        var names: [String: [String]] = [:]
        for (key, entry) in journal where entry.audioFileName != nil || entry.transcriptFileName != nil {
            guard let separator = key.firstIndex(of: ":") else { continue }
            names[String(key[key.index(after: separator)...]), default: []].append(entry.folderName)
        }
        return names.mapValues { $0.sorted() }
    }

    public static func savedFolderNames(from url: URL, noteIds: [String]) -> [String: [String]] {
        let all = savedFolders(from: url)
        return Dictionary(uniqueKeysWithValues: noteIds.compactMap { id in all[noteKey(id)].map { (id, $0) } })
    }
}

/// What marking a spoken note complete did about the listener's folder, in plain words (#3661).
public struct SpokenNoteFolderDelivery: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case saved
        case upToDate
        case keptEdits
        case folderUnavailable
        case failed(String)
    }

    public var folderName: String
    public var state: State

    public init(folderName: String, state: State) {
        self.folderName = folderName
        self.state = state
    }

    var isProblem: Bool {
        switch state {
        case .folderUnavailable, .failed: return true
        case .saved, .upToDate, .keptEdits: return false
        }
    }
}

public enum SpokenNoteFolderOutcome: Equatable, Sendable, Error {
    /// No folder is set up.
    case noFolder
    /// A folder is set up but its delivery is paused.
    case folderPaused
    /// The note has no audio or words on this phone yet.
    case nothingToExport
    case notOnThisPhone
    /// `note.json` can't be read right now; nothing was changed.
    case unreadableNote
    /// `leftOut` says what the files leave out (a take with no words yet), or is empty.
    case delivered([SpokenNoteFolderDelivery], leftOut: String)

    /// Whether the listener has to choose or reselect a folder, so the line offers the way there.
    public var needsFolderChoice: Bool {
        switch self {
        case .noFolder, .folderPaused: return true
        case .delivered(let deliveries, _): return deliveries.contains { $0.state == .folderUnavailable }
        case .nothingToExport, .notOnThisPhone, .unreadableNote: return false
        }
    }

    /// Whether the note failed to reach a folder it should have reached.
    public var isProblem: Bool {
        switch self {
        case .delivered(let deliveries, _):
            return deliveries.contains { $0.isProblem }
        default: return true
        }
    }

    public func line(title: String) -> String {
        let name = "“\(title)”"
        switch self {
        case .noFolder:
            return "No export folder is set, so \(name) wasn't saved to one. Choose a folder in Settings."
        case .folderPaused:
            return "Your notes folder is paused, so \(name) wasn't saved to it. Start delivery in Settings."
        case .nothingToExport:
            return "\(name) has no audio or words to save yet."
        case .notOnThisPhone:
            return "\(name)'s recordings aren't on this phone, so it wasn't saved to your folder."
        case .unreadableNote:
            return "\(name) can't be read right now, so it wasn't saved to your folder. Nothing was changed."
        case .delivered(let deliveries, let leftOut):
            var sentences = deliveries.map { delivery -> String in
                switch delivery.state {
                case .saved: return "Saved \(name) to \(delivery.folderName)."
                case .upToDate: return "\(name) is already in \(delivery.folderName)."
                case .keptEdits: return "\(name) is already in \(delivery.folderName). Files you changed there were left as they are."
                case .folderUnavailable: return "Couldn't reach \(delivery.folderName). Choose it again in Settings. \(name) is safe in your Library."
                case .failed(let reason): return "Couldn't save \(name) to \(delivery.folderName) (\(reason)). \(name) is safe in your Library."
                }
            }
            if !leftOut.isEmpty { sentences.append(leftOut) }
            return sentences.joined(separator: " ")
        }
    }
}
