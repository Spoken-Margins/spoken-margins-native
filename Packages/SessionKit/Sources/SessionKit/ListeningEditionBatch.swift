import Foundation

/// Import several Listening Edition files in one go (#1472). Decoding happens when the files are picked, so
/// the listener sees each file's title and scene count (or its error) before importing, with no Preview.
/// The import itself is a closure, so this type holds no app state and one bad file never stops the others.
public enum ListeningEditionBatch {
    /// What the store already holds for an edition's source.
    public enum Existing: Equatable, Sendable {
        /// Nothing for this source yet, or an older map the import may overwrite.
        case none
        /// The same edition is already in the Library.
        case identical
        /// A different map exists for this source. A batch never replaces it.
        case different
    }

    /// One chosen file (or the pasted JSON), decoded or with the reason it could not be.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let edition: ListeningEdition?
        public let error: String?

        public init(id: Int, name: String, edition: ListeningEdition) {
            self.id = id; self.name = name; self.edition = edition; self.error = nil
        }
        public init(id: Int, name: String, error: String) {
            self.id = id; self.name = name; self.edition = nil; self.error = error
        }
        /// Decodes `data` with the same decoder as the single-file path, so the error text matches.
        public init(id: Int, name: String, data: Data) {
            do { self.init(id: id, name: name, edition: try ListeningEdition.decode(data)) }
            catch { self.init(id: id, name: name, error: error.localizedDescription) }
        }

        /// "Title · 3 scenes", or the error.
        public var detail: String {
            if let edition { return "\(edition.title) · \(edition.scenes.count) \(edition.scenes.count == 1 ? "scene" : "scenes")" }
            return error ?? ""
        }
        public var isValid: Bool { edition != nil }
    }

    public enum Outcome: Equatable, Sendable {
        case imported
        case alreadyImported
        /// A different map exists for this source and was left alone.
        case keptExistingMap
        case failed(String)

        public var isSuccess: Bool { self == .imported || self == .alreadyImported }
        public var isFailure: Bool {
            if case .failed = self { return true }
            return self == .keptExistingMap
        }
    }

    /// The result line for one file.
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let title: String?
        public let outcome: Outcome

        public var message: String {
            let label = title ?? name
            switch outcome {
            case .imported: return "Imported \(label)."
            case .alreadyImported: return "Already imported: \(label)."
            case .keptExistingMap:
                return "\(label): this source already has a different map, so it was not replaced. Import this file on its own to replace it."
            case .failed(let reason): return "\(name): \(reason)"
            }
        }
    }

    /// Imports every valid entry in order. `existing` says what the store holds for an edition's source and
    /// `importOne` imports one edition without opening it or starting playback. A throw from either becomes
    /// that file's failed line and the batch goes on.
    public static func run(_ entries: [Entry],
                           existing: (ListeningEdition) throws -> Existing,
                           importOne: (ListeningEdition) throws -> Void) -> [Line] {
        entries.map { entry in
            guard let edition = entry.edition else {
                return Line(id: entry.id, name: entry.name, title: nil, outcome: .failed(entry.error ?? "Could not be read."))
            }
            do {
                switch try existing(edition) {
                case .identical:
                    return Line(id: entry.id, name: entry.name, title: edition.title, outcome: .alreadyImported)
                case .different:
                    return Line(id: entry.id, name: entry.name, title: edition.title, outcome: .keptExistingMap)
                case .none:
                    try importOne(edition)
                    return Line(id: entry.id, name: entry.name, title: edition.title, outcome: .imported)
                }
            } catch {
                return Line(id: entry.id, name: entry.name, title: edition.title, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// One message for a set of result lines, for a place with no results list (the Add sheet's Files route, #2373).
    /// `isFailure` is true when any file was not imported or kept a different map, and the message then names each one.
    public struct Summary: Equatable, Sendable {
        public let message: String
        public let isFailure: Bool
    }

    public static func summary(of lines: [Line]) -> Summary {
        let imported = lines.filter { $0.outcome == .imported }
        let already = lines.filter { $0.outcome == .alreadyImported }
        let problems = lines.filter { $0.outcome.isFailure }
        let done = imported.count + already.count
        var parts: [String] = []
        if problems.isEmpty {
            if lines.count == 1, let line = lines.first { return Summary(message: line.message, isFailure: false) }
            parts.append("Imported \(imported.count) \(imported.count == 1 ? "edition" : "editions").")
            if !already.isEmpty { parts.append("\(already.count) already in your Library.") }
            return Summary(message: parts.joined(separator: " "), isFailure: false)
        }
        if done > 0 { parts.append("Imported \(done) of \(lines.count) \(lines.count == 1 ? "file" : "files").") }
        else if lines.count > 1 { parts.append("None of the \(lines.count) files could be imported as a Listening Edition.") }
        parts.append(contentsOf: problems.map(\.message))
        return Summary(message: parts.joined(separator: " "), isFailure: true)
    }

    /// "Import 3 editions", "Import 1 edition", or the idle label.
    public static func buttonTitle(count: Int) -> String {
        count == 0 ? "Import Editions" : "Import \(count) \(count == 1 ? "edition" : "editions")"
    }
}
