import Foundation

/// What a saved live session keeps beside its Library item (#2481): the session, the transcript if one was
/// imported, and every Margin's position evidence. Plain fields in a JSON file next to the database; nothing
/// in the database changes.
public struct LiveSessionRecord: Codable, Equatable, Sendable {
    public var itemId: String
    public var session: LiveSession
    public var transcript: ImportedTranscript?
    public var placed: [LiveSessionAlignment.Placed]
    /// Each live Margin's id → the id of the Library Margin it was saved as, so the export follows the item's
    /// Margins as they are now (#2485 audit). Nil in a record saved before the link was kept.
    public var savedMarginIds: [String: String]?

    public init(
        itemId: String, session: LiveSession, transcript: ImportedTranscript?, placed: [LiveSessionAlignment.Placed],
        savedMarginIds: [String: String]? = nil
    ) {
        self.itemId = itemId
        self.session = session
        self.transcript = transcript
        self.placed = placed
        self.savedMarginIds = savedMarginIds
    }

    public static func remove(itemId: String, from directory: URL) {
        try? FileManager.default.removeItem(at: url(itemId: itemId, in: directory))
    }

    /// One of the item's Margins as it is now.
    public struct CurrentMargin: Equatable, Sendable {
        public var id: String
        public var text: String
        /// Where it sits in the recording, for an audio item.
        public var mediaTimeMs: Int?
        public var createdAt: Date

        public init(id: String, text: String, mediaTimeMs: Int?, createdAt: Date) {
            self.id = id
            self.text = text
            self.mediaTimeMs = mediaTimeMs
            self.createdAt = createdAt
        }

        /// An active Margin of the item; nil for one that was deleted.
        public init?(_ margin: Interjection) {
            guard margin.status == "active" else { return nil }
            let text = [margin.cleanedTranscript, margin.transcript, margin.displayText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            self.init(id: margin.id, text: text ?? "", mediaTimeMs: margin.anchor.mediaTimeMs, createdAt: margin.createdAt)
        }
    }

    /// The record as the item's Margins are now (#2485 audit): a Margin deleted from the item is left out, an
    /// edited one says what it says now, and one added after the session (a spoken Margin while replaying the
    /// recording) is added after the session's own. Nil for a record without the id links, so the caller uses
    /// the ordinary export instead of a stale one.
    public func current(_ margins: [CurrentMargin]) -> LiveSessionRecord? {
        guard let savedMarginIds else { return nil }
        let byId = Dictionary(margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = self
        result.session.margins = session.margins.compactMap { margin in
            guard let savedId = savedMarginIds[margin.id], let now = byId[savedId] else { return nil }
            var margin = margin
            if !now.text.isEmpty { margin.text = now.text }
            return margin
        }
        let kept = Set(result.session.margins.map(\.id))
        result.placed = placed.filter { kept.contains($0.id) }.map { placed in
            var placed = placed
            if let text = result.session.margins.first(where: { $0.id == placed.id })?.savedText { placed.text = text }
            return placed
        }
        let linked = Set(savedMarginIds.values)
        for added in margins where !linked.contains(added.id) {
            let text = added.text.isEmpty ? "Spoken Margin, no words yet" : added.text
            result.session.margins.append(LiveSessionMargin(id: added.id, text: text, markedAt: added.createdAt))
            var placed = LiveSessionAlignment.Placed(id: added.id, text: text, offsetMs: added.mediaTimeMs ?? 0)
            placed.estimateMs = nil
            placed.addedLater = true
            placed.listenerMs = added.mediaTimeMs
            placed.source = .listener
            result.placed.append(placed)
        }
        return result
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
        // The session's Margins in the order they were taken, then any added afterwards in recording order.
        let ordered = session.margins.sorted {
            let (lhs, rhs) = (placedById[$0.id]?.addedLater == true, placedById[$1.id]?.addedLater == true)
            if lhs != rhs { return rhs }
            return lhs ? (placedById[$0.id]?.offsetMs ?? 0) < (placedById[$1.id]?.offsetMs ?? 0) : $0.markedAt < $1.markedAt
        }
        for (number, margin) in ordered.enumerated() {
            let placed = placedById[margin.id]
            let at = placed.map { LiveSessionPositionMap.clock($0.offsetMs) }
                ?? LiveSessionPositionMap.position(of: margin, in: session).map(\.label)
            let exact = placed?.source == .transcriptMatch || placed?.addedLater == true
            lines += ["", "## \(number + 1). " + (at.map { exact ? $0 : "About \($0)" } ?? "Margin")]
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
        if placed?.addedLater == true {
            return "Added after the session" + (placed?.listenerMs.map { ", at \(LiveSessionPositionMap.clock($0)) in the recording" } ?? "")
        }
        var parts: [String] = []
        if let matchMs = placed?.matchMs {
            let score = placed?.matchScore.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            // A match that disagreed with the other evidence is still shown, marked as not used (#2485 audit).
            let unused = placed?.source == .transcriptMatch ? "" : ", not used: it disagrees with the other evidence"
            parts.append("Transcript match\(score) at \(LiveSessionPositionMap.clock(matchMs))\(unused)")
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
