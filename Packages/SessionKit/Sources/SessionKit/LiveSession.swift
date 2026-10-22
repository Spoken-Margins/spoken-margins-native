import Foundation

/// A live session (#2481): Margins taken on a clock while something plays outside the app (a meeting, a talk,
/// a video), with nothing recorded. Each Margin keeps the wall-clock moment it was taken. Afterwards the
/// listener lines the session up with a recording they have (`LiveSessionAlignment`), and the Margins land on
/// that recording as an ordinary audio item's Margins.
public struct LiveSession: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var margins: [LiveSessionMargin]

    public init(id: String, startedAt: Date, endedAt: Date? = nil, margins: [LiveSessionMargin] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.margins = margins
    }

    /// Adds blind marks (from the Lock Screen), skipping any already here, in time order.
    /// Returns how many were added.
    @discardableResult
    public mutating func mergeMarks(_ times: [Date]) -> Int {
        let known = Set(margins.filter(\.isBlindMark).map { $0.markedAt.timeIntervalSince1970 })
        let fresh = times
            .filter { !known.contains($0.timeIntervalSince1970) }
            .reduce(into: [Date]()) { if !$0.contains($1) { $0.append($1) } }
        for time in fresh {
            margins.append(LiveSessionMargin(id: "mark-\(Int(time.timeIntervalSince1970 * 1_000))", text: "", markedAt: time, isBlindMark: true))
        }
        margins.sort { $0.markedAt < $1.markedAt }
        return fresh.count
    }
}

public struct LiveSessionMargin: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Empty for a blind mark the listener hasn't written on yet.
    public var text: String
    public var markedAt: Date
    public var isBlindMark: Bool

    public init(id: String, text: String, markedAt: Date, isBlindMark: Bool = false) {
        self.id = id
        self.text = text
        self.markedAt = markedAt
        self.isBlindMark = isBlindMark
    }

    /// What the saved Margin says: the listener's words, or "Mark" for a blind mark left blank.
    public var savedText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mark" : trimmed
    }
}

/// The open live session, kept as one JSON file so it survives the app closing.
public enum LiveSessionStore {
    public static func url(in directory: URL) -> URL {
        directory.appending(path: "LiveSession", directoryHint: .isDirectory).appending(path: "current.json")
    }

    public static func load(from directory: URL) -> LiveSession? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        return try? decoder.decode(LiveSession.self, from: data)
    }

    public static func save(_ session: LiveSession, in directory: URL) throws {
        let target = url(in: directory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601withFractions
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: target, options: .atomic)
    }

    public static func remove(from directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// ISO 8601 with milliseconds: Margin times need more than whole seconds.
    static var iso8601withFractions: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601withFractions: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
    }
}

/// Lines a live session up with a recording: each Margin lands at (its wall-clock time minus the recording's
/// start), plus a nudge the listener sets by ear.
public enum LiveSessionAlignment {
    public enum StartSource: String, Codable, Equatable, Sendable {
        /// The recording's own creation date (AVAsset metadata).
        case metadata
        /// The file's creation date, which can be when it was downloaded rather than recorded.
        case fileDate
        /// Neither was usable, so the recording is taken to start when the session did.
        case sessionStart
    }

    public enum Clamp: String, Equatable, Sendable {
        case beforeStart
        case afterEnd
    }

    public struct Placed: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        /// Where the Margin sits in the recording, within it.
        public var offsetMs: Int
        /// Set when the Margin's own time fell outside the recording and was moved to its edge.
        public var clamp: Clamp?

        public init(id: String, text: String, offsetMs: Int, clamp: Clamp? = nil) {
            self.id = id
            self.text = text
            self.offsetMs = offsetMs
            self.clamp = clamp
        }
    }

    /// The recording's start: its metadata date, else the file's date, else the session's start. A date more
    /// than a day from the session is ignored as not belonging to this recording session (a copied or
    /// re-exported file carries the copy's date).
    public static func recordingStart(
        metadataCreationDate: Date?, fileCreationDate: Date?, session: LiveSession, plausibleWindow: TimeInterval = 86_400
    ) -> (date: Date, source: StartSource) {
        func plausible(_ date: Date?) -> Date? {
            guard let date, abs(date.timeIntervalSince(session.startedAt)) <= plausibleWindow else { return nil }
            return date
        }
        if let date = plausible(metadataCreationDate) { return (date, .metadata) }
        if let date = plausible(fileCreationDate) { return (date, .fileDate) }
        return (session.startedAt, .sessionStart)
    }

    /// Places every Margin. `nudgeMs` moves the recording's start later (positive) or earlier (negative), so a
    /// positive nudge moves every Margin earlier in the recording. Margins outside the recording are clamped
    /// to its first or last moment and marked, never dropped. `durationMs` nil leaves the end unclamped.
    public static func place(
        _ margins: [LiveSessionMargin], recordingStart: Date, nudgeMs: Int = 0, durationMs: Int?
    ) -> [Placed] {
        let start = recordingStart.addingTimeInterval(Double(nudgeMs) / 1_000)
        return margins
            .sorted { $0.markedAt < $1.markedAt }
            .map { margin in
                let raw = Int((margin.markedAt.timeIntervalSince(start) * 1_000).rounded())
                var offset = raw
                var clamp: Clamp?
                if raw < 0 {
                    offset = 0
                    clamp = .beforeStart
                } else if let durationMs, durationMs > 0, raw >= durationMs {
                    offset = durationMs - 1
                    clamp = .afterEnd
                }
                return Placed(id: margin.id, text: margin.savedText, offsetMs: offset, clamp: clamp)
            }
    }
}
