import Foundation

// A short, persisted log of the voice download path (#2224): which catalog stood, whether its signature
// verified, what the installer downloaded, retried, finished or failed. The Diagnostics export reads it from
// the file, so a download from an earlier launch is still there. Agents check phone behaviour from that
// export; before this, a voice that "downloaded well" left nothing to show how.
//
// Only step names, counts, ids, versions and reasons go in: a web address is reduced to its host, and a
// file-system path never goes in. The owner's data and listener identifiers are not available here to leak.

public final class VoiceDownloadLog: @unchecked Sendable {
    public struct Event: Codable, Equatable, Sendable {
        public var time: String
        public var kind: String
        public var fields: [String: String]
    }

    private struct Capture: Codable {
        var schemaVersion: String
        var events: [Event]
    }

    public static let schemaVersion = "spoken-margins.voice-downloads.v1"
    /// The newest this many events are kept. A whole install is a few dozen, and each visit to Voices adds about four.
    public static let defaultLimit = 400
    public static let fileName = "download-log.json"

    private let fileURL: URL?
    private let limit: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var events: [Event] = []

    /// `fileURL` nil keeps the log in memory only (tests, previews). An existing file is read back, so
    /// events from an earlier launch stay in the log.
    public init(fileURL: URL?, limit: Int = VoiceDownloadLog.defaultLimit, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.limit = max(2, limit)
        self.now = now
        if let fileURL, let stored = Self.read(fileURL) { events = Array(stored.suffix(self.limit)) }
    }

    /// Where the coordinator keeps it: next to the cached catalog, outside backups like the rest of that folder.
    public static func fileURL(stateFolder: URL) -> URL {
        stateFolder.appending(path: fileName)
    }

    public func record(_ kind: String, _ fields: [String: String] = [:]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event = Event(time: formatter.string(from: now()), kind: kind, fields: fields.mapValues(Self.sanitized))
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        persist()
    }

    public var snapshot: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// The JSON text the export carries, or nil when nothing was ever recorded.
    public func exportJSON() -> String? {
        Self.exportJSON(events: snapshot)
    }

    /// The export read straight from the file, for the app when no download has run since launch. A
    /// missing or unreadable file gives nil.
    public static func exportJSON(fileURL: URL) -> String? {
        guard let events = read(fileURL) else { return nil }
        return exportJSON(events: events)
    }

    private static func exportJSON(events: [Event]) -> String? {
        guard !events.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Capture(schemaVersion: schemaVersion, events: events)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: What may go in

    /// Any scheme://address becomes its host; a path (to the next quote or bracket, since iOS folders hold spaces) is dropped. Anything longer than 200
    /// characters is cut, so a stray error text can't fill the log.
    public static func sanitized(_ value: String) -> String {
        var text = value
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"')\]]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                text.replaceSubrange(matchRange, with: host(of: String(text[matchRange])))
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"/(?:private|Users|var|Library|tmp|data)/[^"')\]]*"#) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                text.replaceSubrange(matchRange, with: "<path>")
            }
        }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    /// The host of a web address, or `unknown` when it has none.
    public static func host(of address: String) -> String {
        URL(string: address)?.host ?? "unknown"
    }

    // MARK: File

    private static func read(_ fileURL: URL) -> [Event]? {
        guard let data = try? Data(contentsOf: fileURL),
              let capture = try? JSONDecoder().decode(Capture.self, from: data),
              capture.schemaVersion == schemaVersion else { return nil }
        return capture.events
    }

    /// Called under the lock. A failed write loses nothing in memory and is not worth failing a download for.
    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Capture(schemaVersion: Self.schemaVersion, events: events)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
