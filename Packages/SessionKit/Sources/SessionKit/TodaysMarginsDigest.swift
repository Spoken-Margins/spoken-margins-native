import Foundation

/// The "Today's Margins" Shortcuts action's text (#1991): every Margin the listener made on one local calendar day,
/// on Library items and in live and quick sessions, in the order they were made, as Markdown a chatbot or a notes app can read. Pure: it reads nothing, so the day's
/// boundaries, the empty day and the order are host-tested here, and the store read lives in `SessionKitPersistence`.
///
/// What a Margin contributes is what the notes folder's note for it would say (`SessionExportMarkdownRenderer`): the
/// listener's own words, a spoken Margin whose transcript hasn't arrived marked as such, and a written Margin with no
/// words left out. Nothing here goes anywhere until the listener runs the action.
public enum TodaysMarginsDigest {
    /// One Margin as the digest lists it.
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let itemTitle: String
        public let takenAt: Date
        /// The listener's words; empty for a spoken Margin whose transcript hasn't arrived.
        public let words: String
        /// "at 12:04" (a Margin with a clock time), "about 34% through" (a text), "on the summary" or "on an answer".
        public let place: String
        public let isSpoken: Bool

        public init(id: String, itemTitle: String, takenAt: Date, words: String, place: String, isSpoken: Bool) {
            self.id = id
            self.itemTitle = itemTitle
            self.takenAt = takenAt
            self.words = words
            self.place = place
            self.isSpoken = isSpoken
        }
    }

    /// Shown for a spoken Margin whose words aren't written yet, so the Margin still counts.
    public static let notTranscribedYet = "(Spoken Margin, not written out yet.)"

    /// What the digest says on a day with no Margins.
    public static let emptyDay = "No Margins today."

    /// The Margin's words as the notes folder would write them: a written Margin's own text, else the cleaned
    /// transcript, else the raw one. Whitespace at the ends is trimmed.
    public static func words(of margin: Interjection) -> String {
        let text = margin.captureKind == .written
            ? margin.transcript
            : margin.cleanedTranscript ?? margin.transcript
        return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the Margin sits, in the listener's terms: the clock time in a recording, how far through a text, or what
    /// it was said about when it isn't on the source itself.
    public static func place(of margin: Interjection) -> String {
        switch margin.targetType {
        case .summaryTurn: return "on the summary"
        case .assistantTurn: return "on an answer"
        case .item:
            if let ms = margin.anchor.mediaTimeMs { return "at \(MarginDeepLink.clockPosition(ms: ms))" }
            return "about \(min(100, max(0, margin.roughPercent)))% through"
        }
    }

    /// The day's entries, earliest first. A Margin counts when it is active, was made on `day`'s calendar day (a
    /// stored counter date from before #624 is read as its session's start, as the notes folder does), and either
    /// has words or was spoken. Margins on the same moment keep a stable order by id.
    /// - `margins`: every active Margin to consider, each with its item's title and its session (for the old dates).
    /// - `madeAt`: for a Margin saved from a live session, the moment it was made there (`madeAt(records:)`). Saving a
    ///   session writes each Margin to the database stamped with the save time, so without this a Margin made at 10:05
    ///   and saved at 16:00, or the next morning, would be dated by the save.
    public static func entries(
        from margins: [(margin: Interjection, itemTitle: String, session: Session?)],
        on day: Date,
        calendar: Calendar = .current,
        madeAt: [String: Date] = [:]
    ) -> [Entry] {
        let found = margins
            .compactMap { candidate -> Entry? in
                let margin = candidate.margin
                guard margin.status == "active" else { return nil }
                let takenAt = madeAt[margin.id] ?? margin.recordedAt(in: candidate.session)
                guard calendar.isDate(takenAt, inSameDayAs: day) else { return nil }
                let words = words(of: margin)
                let isSpoken = margin.captureKind != .written
                guard isSpoken || !words.isEmpty else { return nil }
                return Entry(
                    id: margin.id, itemTitle: candidate.itemTitle, takenAt: takenAt, words: words,
                    place: place(of: margin), isSpoken: isSpoken)
            }
        return ordered(found)
    }

    /// When each Margin that was saved from a live session was made there, by the id it has in the database. A record
    /// saved before the links were kept (`savedMarginIds` nil) adds nothing, and its Margins keep their stored time.
    public static func madeAt(records: [LiveSessionRecord]) -> [String: Date] {
        var made: [String: Date] = [:]
        for record in records {
            guard let links = record.savedMarginIds else { continue }
            let markedAt = Dictionary(record.session.margins.map { ($0.id, $0.markedAt) }, uniquingKeysWith: { first, _ in first })
            for (liveId, storedId) in links {
                if let at = markedAt[liveId] { made[storedId] = at }
            }
        }
        return made
    }

    /// Earliest first; the same moment keeps a stable order by id.
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { ($0.takenAt, $0.id) < ($1.takenAt, $1.id) }
    }

    /// The day's Margins in live sessions (a meeting, an audiobook or paper book elsewhere) and quick sessions, which
    /// are kept as files and not in the database (#2487), unordered: merge them with `entries(from:on:calendar:)`'s
    /// through `ordered`. A session already saved as a Library item is skipped, since its Margins are on the item and
    /// counted there. A blind Mark with no words is left out, as a blank written Margin is; a spoken Margin whose
    /// transcript hasn't arrived is kept. The title is the session's own, else "Quick session" or "<kind> session".
    public static func entries(
        fromLiveSessions sessions: [LiveSession], on day: Date, calendar: Calendar = .current
    ) -> [Entry] {
        sessions.filter { $0.savedItemId == nil }.flatMap { session -> [Entry] in
            session.margins.compactMap { margin -> Entry? in
                guard calendar.isDate(margin.markedAt, inSameDayAs: day) else { return nil }
                let words = margin.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSpoken = margin.audioPath != nil
                guard isSpoken || !words.isEmpty else { return nil }
                return Entry(
                    id: margin.id, itemTitle: LiveSessionFileWorker.title(of: session), takenAt: margin.markedAt,
                    words: words, place: place(of: margin), isSpoken: isSpoken)
            }
        }
    }

    /// What the listener said about where they were (their words, else the place they gave), else how far into the
    /// session it was.
    static func place(of margin: LiveSessionMargin) -> String {
        let said = margin.whereNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !said.isEmpty { return said }
        if let place = margin.place { return place.label }
        return "\(MarginDeepLink.clockPosition(ms: margin.sessionOffsetMs)) into the session"
    }

    /// The text the action returns.
    ///
    ///     # Margins for Thu 12 Nov 2026
    ///
    ///     2 Margins.
    ///
    ///     ## 09:14 · Episode title
    ///     at 12:04
    ///
    ///     > The listener's words.
    ///
    /// The words are quoted line by line, so a Margin that says "# Plan" can't read as a heading of the digest. A title
    /// goes on one line with Markdown's inline marks escaped.
    public static func markdown(
        _ entries: [Entry], day: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let dayFormat = DateFormatter()
        dayFormat.locale = locale
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.dateFormat = "EEE d MMM yyyy"
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"

        var lines = ["# Margins for \(dayFormat.string(from: day))", ""]
        guard !entries.isEmpty else {
            lines.append(emptyDay)
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append(entries.count == 1 ? "1 Margin." : "\(entries.count) Margins.")
        for entry in entries {
            lines.append("")
            lines.append("## \(clock.string(from: entry.takenAt)) · \(oneLine(entry.itemTitle))")
            lines.append(entry.place)
            lines.append("")
            let words = entry.words.isEmpty ? notTranscribedYet : entry.words
            lines.append(contentsOf: words.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A title on one line, with Markdown's own marks escaped so it can't turn the heading into something else.
    static func oneLine(_ title: String) -> String {
        let flat = title
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let escaped = flat.reduce(into: "") { result, character in
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return escaped.isEmpty ? "Untitled" : escaped
    }
}
