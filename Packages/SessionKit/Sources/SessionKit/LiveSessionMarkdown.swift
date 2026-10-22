import Foundation

/// What a saved live session keeps beside its Library item (#2481): the session, the transcript if one was
/// imported, and every Margin's position evidence. Plain fields in a JSON file next to the database; nothing
/// in the database changes.
public struct LiveSessionRecord: Codable, Equatable, Sendable {
    public var itemId: String
    public var session: LiveSession
    public var transcript: ImportedTranscript?
    public var placed: [LiveSessionAlignment.Placed]

    public init(itemId: String, session: LiveSession, transcript: ImportedTranscript?, placed: [LiveSessionAlignment.Placed]) {
        self.itemId = itemId
        self.session = session
        self.transcript = transcript
        self.placed = placed
    }

    public static func url(itemId: String, in directory: URL) -> URL {
        let safe = itemId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appending(path: "LiveSessions", directoryHint: .isDirectory).appending(path: String(safe) + ".json")
    }

    public func save(in directory: URL) throws {
        let target = Self.url(itemId: itemId, in: directory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601withFractions
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }

    public static func load(itemId: String, from directory: URL) -> LiveSessionRecord? {
        guard let data = try? Data(contentsOf: url(itemId: itemId, in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        return try? decoder.decode(LiveSessionRecord.self, from: data)
    }
}

/// The live session as Markdown (#2481), the session's main export: a header (title, kind, date, start and
/// end positions), one section per Margin with every position the evidence gives and the matched transcript
/// line quoted, and optionally the transcript as an appendix.
public enum LiveSessionMarkdown {
    public static func render(_ record: LiveSessionRecord, includeTranscript: Bool = true, timeZone: TimeZone = .current) -> String {
        let session = record.session
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = ["# " + (title.isEmpty ? "\(session.kind.label) session" : title), ""]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("- Kind: \(session.kind.label)")
        var when = "- Date: \(formatter.string(from: session.startedAt))"
        if let end = session.endedAt {
            formatter.dateFormat = "HH:mm"
            when += " to \(formatter.string(from: end))"
        }
        lines.append(when)
        if let start = session.startPositionMs { lines.append("- Started at: \(LiveSessionPositionMap.clock(start))") }
        if let end = session.endPositionMs { lines.append("- Ended at: \(LiveSessionPositionMap.clock(end))") }
        if let bracket = session.bracket { lines.append("- Where: \(bracket)") }
        lines.append("- Margins: \(session.margins.count)")

        let placedById = Dictionary(record.placed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (number, margin) in session.margins.sorted(by: { $0.markedAt < $1.markedAt }).enumerated() {
            let placed = placedById[margin.id]
            let at = placed.map { LiveSessionPositionMap.clock($0.offsetMs) }
                ?? LiveSessionPositionMap.position(of: margin, in: session).map(\.label)
            lines += ["", "## \(number + 1). " + (at.map { placed?.source == .transcriptMatch ? $0 : "About \($0)" } ?? "Margin")]
            lines += ["", margin.isBlindMark && margin.text.trimmingCharacters(in: .whitespaces).isEmpty ? "_Mark, no words._" : margin.savedText]
            if let note = margin.whereNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines += ["", "Where: \(note) or so."]
            }
            lines += ["", "Position: " + evidence(margin: margin, placed: placed, session: session)]
            if let text = placed?.matchText {
                let speaker = placed?.matchSpeaker.map { "\($0): " } ?? ""
                lines += ["", "> " + speaker + text]
            }
        }
        if includeTranscript, let transcript = record.transcript, !transcript.cues.isEmpty {
            lines += ["", "## Appendix: transcript", ""]
            for cue in transcript.cues {
                let speaker = cue.speaker.map { "**\($0):** " } ?? ""
                lines.append("[\(LiveSessionPositionMap.clock(cue.startMs))] " + speaker + cue.text)
                lines.append("")
            }
            if lines.last == "" { lines.removeLast() }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Transcript match 90% at 1:24:02 · you set 1:23:30 · estimate about 1:23:10", best evidence first.
    public static func evidence(margin: LiveSessionMargin, placed: LiveSessionAlignment.Placed?, session: LiveSession) -> String {
        var parts: [String] = []
        if let matchMs = placed?.matchMs {
            let score = placed?.matchScore.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            parts.append("Transcript match\(score) at \(LiveSessionPositionMap.clock(matchMs))")
        }
        if let listener = placed?.listenerMs ?? margin.listenerPositionMs {
            parts.append("you set \(LiveSessionPositionMap.clock(listener))")
        }
        if let estimate = placed?.estimateMs {
            parts.append("estimate about \(LiveSessionPositionMap.clock(estimate))")
        } else if let position = LiveSessionPositionMap.position(at: margin.markedAt, in: session) {
            parts.append("estimate \(position.label)")
        }
        parts.append("\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) into the session")
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
