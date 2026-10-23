import Foundation

/// Why a saved Margin may be shorter than the listener meant (#1976).
public enum CutShortMark: String, Equatable, Sendable {
    /// A call, Siri or another app took the microphone, and what was said so far was saved.
    case interrupted
    /// The headphones disconnected mid-recording, and what was said so far was saved.
    case headphonesDisconnected
    /// The app closed while recording; the recording was found on the next launch and kept as a Margin.
    case recovered

    /// The short tag on a row.
    public var tag: String {
        switch self {
        case .interrupted, .headphonesDisconnected: "Cut short"
        case .recovered: "Recovered"
        }
    }

    /// The line in the Margin's detail, which says why.
    public var explanation: String {
        switch self {
        case .interrupted: "A call or Siri cut this Margin short. What you said before that is saved."
        case .headphonesDisconnected: "Your headphones disconnected while you were recording. What you said before that is saved."
        case .recovered: "The app closed while you were recording. This is what was saved."
        }
    }
}

/// The Margins a listener may want to re-record because they ended early. It is a small side file, not a column, so
/// the previous build still opens the database and a packet never carries it. A Margin is marked when it is saved and
/// loses the mark once the listener opens it. Keys are `sessionId::interjectionId`, because Margin ids count up
/// within one session.
public final class CutShortMargins: @unchecked Sendable {
    public static let shared = CutShortMargins()

    private let lock = NSLock()
    private var fileURL: URL?
    private var marks: [String: CutShortMark] = [:]

    public init(fileURL: URL? = nil) {
        if let fileURL { use(fileURL: fileURL) }
    }

    public static func standardFileURL(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "SpokenMargins", directoryHint: .isDirectory).appending(path: "cut-short-margins.json")
    }

    public var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileURL != nil
    }

    /// Points the store at its file and reads what is there, keeping any mark already set in memory. A missing or
    /// unreadable file means no marks. Pointing at the file it already uses does nothing.
    public func use(fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.fileURL != fileURL else { return }
        self.fileURL = fileURL
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        marks = stored.compactMapValues(CutShortMark.init(rawValue:)).merging(marks) { _, inMemory in inMemory }
        save()
    }

    public static func key(sessionId: String, interjectionId: String) -> String { "\(sessionId)::\(interjectionId)" }

    public func mark(sessionId: String, interjectionId: String) -> CutShortMark? {
        lock.lock()
        defer { lock.unlock() }
        return marks[Self.key(sessionId: sessionId, interjectionId: interjectionId)]
    }

    public func set(_ mark: CutShortMark, sessionId: String, interjectionId: String) {
        lock.lock()
        defer { lock.unlock() }
        marks[Self.key(sessionId: sessionId, interjectionId: interjectionId)] = mark
        save()
    }

    /// - Returns: true when a mark was removed.
    @discardableResult
    public func clear(sessionId: String, interjectionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard marks.removeValue(forKey: Self.key(sessionId: sessionId, interjectionId: interjectionId)) != nil else { return false }
        save()
        return true
    }

    // Callers hold the lock. A failed write leaves the mark in memory for this launch and costs nothing else.
    private func save() {
        guard let fileURL else { return }
        let raw = marks.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
