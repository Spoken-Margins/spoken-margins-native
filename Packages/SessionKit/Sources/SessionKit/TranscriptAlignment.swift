import Foundation

/// Lines a live session's Margins up with a meeting transcript (#2481), using the strongest evidence there is:
///
/// 1. Text match. A Margin whose words are in the transcript (a spoken Margin said unmuted, or a typed quote)
///    pins the transcript's start: its wall time minus the matching cue's start. Matched Margins sit on their
///    cue exactly.
/// 2. The transcript's own start date, from its header.
/// 3. The listener's rough start time, else their "where are you now?" at the session's start (the meeting
///    clock), else the session's start, plus a nudge they set by ear.
public enum TranscriptAlignment {
    public enum Method: String, Equatable, Sendable {
        case textMatch
        case transcriptStart
        case roughStart
    }

    public struct Result: Equatable, Sendable {
        /// The wall-clock moment of the transcript's time zero, nudge included.
        public var transcriptStart: Date
        public var method: Method
        /// Margin id → the cue it matched.
        public var matches: [String: Int]
        public var placed: [LiveSessionAlignment.Placed]
    }

    /// Where time zero falls without a text match: the transcript's own date, its time of day on the session's
    /// date, the listener's rough start, or the session's start.
    public static func fallbackStart(
        transcript: ImportedTranscript, session: LiveSession, roughStart: Date?, calendar: Calendar = .current
    ) -> (date: Date, method: Method) {
        if let absolute = transcript.absoluteStart { return (absolute, .transcriptStart) }
        if let seconds = transcript.startTimeOfDaySeconds {
            let day = calendar.startOfDay(for: session.startedAt)
            var date = day.addingTimeInterval(TimeInterval(seconds))
            // Captions that began before midnight for a session that started after it.
            if date.timeIntervalSince(session.startedAt) > 12 * 3_600 { date = date.addingTimeInterval(-86_400) }
            return (date, .transcriptStart)
        }
        if let roughStart { return (roughStart, .roughStart) }
        // "Where are you now?" at the start: the meeting clock read 2:00, so its zero was two minutes earlier.
        if let position = session.startPositionMs {
            return (session.startedAt.addingTimeInterval(-Double(position) / 1_000), .roughStart)
        }
        return (session.startedAt, .roughStart)
    }

    public static func align(
        session: LiveSession,
        transcript: ImportedTranscript,
        roughStart: Date? = nil,
        nudgeMs: Int = 0,
        matchThreshold: Double = 0.6,
        calendar: Calendar = .current
    ) -> Result {
        var matches: [String: Int] = [:]
        var estimates: [TimeInterval] = []
        for margin in session.margins where !margin.isBlindMark {
            guard let (cue, _) = bestCue(for: margin.text, in: transcript.cues, threshold: matchThreshold) else { continue }
            matches[margin.id] = cue
            estimates.append(margin.markedAt.timeIntervalSince1970 - Double(transcript.cues[cue].startMs) / 1_000)
        }
        let base: Date
        let method: Method
        if !estimates.isEmpty {
            base = Date(timeIntervalSince1970: median(estimates))
            method = .textMatch
        } else {
            (base, method) = fallbackStart(transcript: transcript, session: session, roughStart: roughStart, calendar: calendar)
        }
        let start = base.addingTimeInterval(Double(nudgeMs) / 1_000)
        var placed = LiveSessionAlignment.place(session.margins, recordingStart: start, durationMs: transcript.durationMs.map { $0 + 1 })
        for index in placed.indices {
            if let cue = matches[placed[index].id] {
                placed[index].offsetMs = transcript.cues[cue].startMs
                placed[index].clamp = nil
            }
        }
        return Result(transcriptStart: start, method: method, matches: matches, placed: placed)
    }

    /// The cue (or the cue that starts a run of up to three) whose words best cover `text`. A match needs at
    /// least three words and `threshold` of them found; ties go to the earlier cue.
    public static func bestCue(for text: String, in cues: [TranscriptCue], threshold: Double = 0.6) -> (index: Int, score: Double)? {
        let wanted = tokens(text)
        guard wanted.count >= 3 else { return nil }
        let cueTokens = cues.map { Set(tokens($0.text)) }
        // Single cues first, then runs of two and three: a run wins only when it covers more of the words, so a
        // quote within one cue lands on that cue, not on a run that happens to include it.
        var best: (index: Int, score: Double, size: Int)?
        for size in 1...3 {
            for start in cues.indices where start + size <= cues.count {
                let run = (start..<(start + size)).map { cueTokens[$0] }
                // Every cue in a run must add words, or the shorter run already says it.
                guard size == 1 || run.allSatisfy({ !Set(wanted).isDisjoint(with: $0) }) else { continue }
                let window = run.reduce(into: Set<String>()) { $0.formUnion($1) }
                let score = Double(wanted.filter { window.contains($0) }.count) / Double(wanted.count)
                if score >= threshold, score > (best?.score ?? 0) + 1e-9 { best = (start, score, size) }
            }
        }
        return best.map { ($0.index, $0.score) }
    }

    /// Lowercased words with accents and punctuation removed.
    public static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The text of an item made from a live session (#1989, #2481), with where each Margin lands in it.
public enum LiveSessionText {
    public struct Built: Equatable, Sendable {
        public var text: String
        public var placed: [LiveSessionAlignment.Placed]
    }

    /// The transcript as the item's text, one paragraph per cue ("Alice Example: Welcome…"), with each placed
    /// Margin at the start of the cue that holds its time.
    public static func transcript(_ transcript: ImportedTranscript, placed: [LiveSessionAlignment.Placed]) -> Built {
        var text = ""
        var cueStarts: [Int] = []
        for cue in transcript.cues {
            if !text.isEmpty { text += "\n\n" }
            cueStarts.append(text.count)
            text += cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text
        }
        let starts = transcript.cues.map(\.startMs)
        let located = placed.map { margin -> LiveSessionAlignment.Placed in
            var margin = margin
            let index = starts.lastIndex { $0 <= margin.offsetMs } ?? 0
            margin.charOffset = cueStarts.isEmpty ? 0 : cueStarts[index]
            return margin
        }
        return Built(text: text, placed: located)
    }

    /// For a session with no transcript or recording (an audiobook in another app, a paper book): a short
    /// record of the session, one line per Margin with how far in it was taken and the listener's own
    /// "where I am", never a claimed position. Each Margin sits on its line.
    public static func notes(_ session: LiveSession) -> Built {
        var text = "\(session.kind.label) session"
        if let bracket = session.bracket { text += ", \(bracket)" }
        text += "."
        var placed: [LiveSessionAlignment.Placed] = []
        for margin in session.margins.sorted(by: { $0.markedAt < $1.markedAt }) {
            text += "\n\n"
            let offset = text.count
            var line = "\(clock(margin.sessionOffsetMs)) into the session"
            if let position = LiveSessionPositionMap.position(at: margin.markedAt, in: session) {
                line += ", at \(position.label)"
            }
            if let note = margin.whereNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                line += ", \(note) or so"
            }
            text += line + "."
            placed.append(LiveSessionAlignment.Placed(id: margin.id, text: margin.savedText, offsetMs: margin.sessionOffsetMs, charOffset: offset))
        }
        return Built(text: text, placed: placed)
    }

    static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms / 1_000)
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
