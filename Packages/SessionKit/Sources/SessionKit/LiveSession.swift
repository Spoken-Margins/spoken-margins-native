import Foundation

/// What a live session is about (#1989, #2481): something played or read outside the app.
public enum ElsewhereKind: String, Codable, CaseIterable, Sendable {
    case meeting
    case audiobook
    case paper
    case other

    public var label: String {
        switch self {
        case .meeting: "Meeting"
        case .audiobook: "Audiobook"
        case .paper: "Paper book"
        case .other: "Something else"
        }
    }
}

/// A live session (#1989, generalised in #2481): Margins taken while something plays or is read outside the
/// app (a meeting, an audiobook in another app, a paper book), with nothing recorded. The app knows only when
/// each Margin was taken and what the listener tells it about where they were; it never claims a position it
/// doesn't have. A meeting can later be lined up with its transcript (`TranscriptAlignment`) or recording.
public struct LiveSession: Codable, Equatable, Sendable {
    public var id: String
    public var kind: ElsewhereKind
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// "Where are you now?" as a time in the source when the session started and ended: 0:00 at the start of
    /// an audiobook, 2:00 when the meeting clock shows two minutes. The main field; `LiveSessionPositionMap`
    /// turns it into each Margin's approximate position.
    public var startPositionMs: Int?
    public var endPositionMs: Int?
    /// "Where I am" as a chapter or page (#1989), the only option for a paper book.
    public var startWhere: String?
    public var endWhere: String?
    public var margins: [LiveSessionMargin]

    public init(
        id: String, kind: ElsewhereKind = .meeting, title: String = "", startedAt: Date, endedAt: Date? = nil,
        startPositionMs: Int? = nil, endPositionMs: Int? = nil,
        startWhere: String? = nil, endWhere: String? = nil, margins: [LiveSessionMargin] = []
    ) {
        self.startPositionMs = startPositionMs
        self.endPositionMs = endPositionMs
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startWhere = startWhere
        self.endWhere = endWhere
        self.margins = margins
    }

    /// A Margin taken at `markedAt`, with its offset into the session.
    public func margin(id: String, text: String, markedAt: Date, whereNote: String? = nil, isBlindMark: Bool = false) -> LiveSessionMargin {
        LiveSessionMargin(
            id: id, text: text, markedAt: markedAt,
            sessionOffsetMs: max(0, Int((markedAt.timeIntervalSince(startedAt) * 1_000).rounded())),
            whereNote: whereNote, isBlindMark: isBlindMark
        )
    }

    /// "Chapter 4 to Chapter 6", "From page 30", or nil: only what the listener said, never a position.
    public var bracket: String? {
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let start = trimmed(startWhere)
        let end = trimmed(endWhere)
        switch (start, end) {
        case let (start?, end?): return start == end ? start : "\(start) to \(end)"
        case let (start?, nil): return "From \(start)"
        case let (nil, end?): return "Up to \(end)"
        case (nil, nil): return nil
        }
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
            margins.append(margin(id: "mark-\(Int(time.timeIntervalSince1970 * 1_000))", text: "", markedAt: time, isBlindMark: true))
        }
        margins.sort { $0.markedAt < $1.markedAt }
        return fresh.count
    }
}

public struct LiveSessionMargin: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Empty for a blind mark the listener hasn't written on yet.
    public var text: String
    /// The wall-clock moment it was taken.
    public var markedAt: Date
    /// How far into the session it was taken.
    public var sessionOffsetMs: Int
    /// The listener's "where I am" (chapter, page, slide), if they gave one.
    public var whereNote: String?
    public var isBlindMark: Bool
    /// A source position the listener slid to by hand while taking the Margin. It is never moved
    /// automatically; a transcript anchor that disagrees is only offered as a suggestion.
    public var listenerPositionMs: Int?
    /// A spoken Margin's recording (#2487), named the way the app's Margin recorder names it
    /// ("SpokenMargins/interjections/…"). `text` then holds its on-device transcript, empty until it is transcribed.
    /// Nil for a written Margin or a Mark. Optional, so a session saved by an earlier build still reads.
    public var audioPath: String?
    /// How long the spoken Margin is.
    public var durationMs: Int?
    /// Where it was spoken: "phone" or "watch". Nil for a written Margin or a Mark.
    public var spokenOn: String?

    public init(
        id: String, text: String, markedAt: Date, sessionOffsetMs: Int = 0, whereNote: String? = nil, isBlindMark: Bool = false,
        listenerPositionMs: Int? = nil, audioPath: String? = nil, durationMs: Int? = nil, spokenOn: String? = nil
    ) {
        self.audioPath = audioPath
        self.durationMs = durationMs
        self.spokenOn = spokenOn
        self.listenerPositionMs = listenerPositionMs
        self.id = id
        self.text = text
        self.markedAt = markedAt
        self.sessionOffsetMs = sessionOffsetMs
        self.whereNote = whereNote
        self.isBlindMark = isBlindMark
    }

    /// What the saved Margin says: the listener's words, or "Mark" for a blind mark left blank.
    public var savedText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return isSpoken ? "Spoken Margin" : "Mark"
    }

    public var isSpoken: Bool { audioPath != nil }

    /// The spoken Margin's transcript, when it has one.
    public var spokenTranscript: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSpoken && !trimmed.isEmpty ? trimmed : nil
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

    /// Which evidence a Margin is placed by in the player: a transcript match (only confident ones are kept),
    /// else the listener's own setting, else the estimate. The others stay alongside it.
    public enum PositionSource: String, Codable, Equatable, Sendable {
        case transcriptMatch
        case listener
        case estimate
    }

    public static func best(estimateMs: Int, listenerMs: Int?, matchMs: Int?) -> (offsetMs: Int, source: PositionSource) {
        if let matchMs { return (matchMs, .transcriptMatch) }
        if let listenerMs { return (listenerMs, .listener) }
        return (estimateMs, .estimate)
    }

    public enum Clamp: String, Codable, Equatable, Sendable {
        case beforeStart
        case afterEnd
    }

    public struct Placed: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        /// Where the Margin sits in the recording, within it.
        public var offsetMs: Int
        /// Set when the Margin's own time fell outside the recording and was moved to its edge.
        public var clamp: Clamp?
        /// Where it sits in the item's text, for an item with no audio (a transcript or session notes).
        public var charOffset: Int?
        /// Which evidence `offsetMs` came from.
        public var source: PositionSource = .estimate
        // Every piece of position evidence, kept side by side (owner, 2026-10-22): none is thrown away.
        /// The start/end estimate ("about").
        public var estimateMs: Int?
        /// The listener's own setting, if they slid it.
        public var listenerMs: Int?
        /// The transcript match: where, the cue's words and speaker, and how sure (0...1).
        public var matchMs: Int?
        public var matchText: String?
        public var matchSpeaker: String?
        public var matchScore: Double?
        /// A spoken Margin's recording and transcript (#2487); the placer writes it as a spoken Margin.
        public var audioPath: String?
        public var transcript: String?
        /// A Margin added to the item after the session, placed where the listener took it in the recording.
        public var addedLater: Bool?

        public init(id: String, text: String, offsetMs: Int, clamp: Clamp? = nil, charOffset: Int? = nil) {
            self.id = id
            self.text = text
            self.offsetMs = offsetMs
            self.clamp = clamp
            self.charOffset = charOffset
            self.estimateMs = offsetMs
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
                var placed = Placed(id: margin.id, text: margin.savedText, offsetMs: offset, clamp: clamp)
                placed.audioPath = margin.audioPath
                placed.transcript = margin.spokenTranscript
                return placed
            }
    }
}
