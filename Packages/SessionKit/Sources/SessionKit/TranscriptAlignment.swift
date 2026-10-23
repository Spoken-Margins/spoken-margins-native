import Foundation

/// Lines a live session's Margins up with a meeting transcript (#2481), using the strongest evidence there is:
///
/// 1. Text match. A Margin whose distinctive words are in the transcript (a spoken Margin said unmuted, or a
///    typed quote) says where the transcript's start falls: its wall time minus the matching cue's start. The
///    transcript is moved only when two or more matches agree on it; a single match never moves the other
///    Margins (#2485 audit), it only places its own.
/// 2. The transcript's own start date, from its header.
/// 3. The listener's rough start time, else their "where are you now?" at the session's start (the meeting
///    clock), else the session's start, plus a nudge they set by ear.
///
/// A match places its own Margin only when it agrees with that start and with the listener's own setting.
/// One that disagrees is set aside: kept and reported as evidence, never used to place anything.
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
        /// Margin id → the cue it matched, for the matches that place their Margin.
        public var matches: [String: Int]
        /// Margin id → a cue it matched that disagreed with the rest of the evidence: reported, not used.
        public var setAside: [String: Int] = [:]
        public var placed: [LiveSessionAlignment.Placed]
    }

    /// How closely two text matches must agree on the transcript's start to move it together.
    public static let anchorAgreementSeconds: TimeInterval = 120

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
        var anchors: [(id: String, cue: Int, score: Double, zero: TimeInterval)] = []
        for margin in session.margins where !margin.isBlindMark {
            guard let (cue, score) = bestCue(for: margin.text, in: transcript.cues, threshold: matchThreshold) else { continue }
            anchors.append((margin.id, cue, score, margin.markedAt.timeIntervalSince1970 - Double(transcript.cues[cue].startMs) / 1_000))
        }
        let window = session.endPositionMs == nil ? hintWindowWithoutEndMs : hintWindowMs
        let windowSeconds = Double(window) / 1_000
        let fallback = fallbackStart(transcript: transcript, session: session, roughStart: roughStart, calendar: calendar)
        // The largest group of matches that agree with each other; ties go to the group nearest the fallback.
        let groups = anchors.map { anchor in anchors.filter { abs($0.zero - anchor.zero) <= anchorAgreementSeconds }.map(\.zero) }
        let distance = { (zeros: [TimeInterval]) in abs(median(zeros) - fallback.date.timeIntervalSince1970) }
        let agreeing = groups.max { $0.count != $1.count ? $0.count < $1.count : distance($0) > distance($1) }
        let base: Date
        let method: Method
        if let agreeing, agreeing.count >= 2 {
            base = Date(timeIntervalSince1970: median(agreeing))
            method = .textMatch
        } else {
            (base, method) = fallback
        }
        var matches: [String: Int] = [:]
        var setAside: [String: Int] = [:]
        var scores: [String: Double] = [:]
        for anchor in anchors {
            scores[anchor.id] = anchor.score
            if abs(anchor.zero - base.timeIntervalSince1970) <= windowSeconds { matches[anchor.id] = anchor.cue } else { setAside[anchor.id] = anchor.cue }
        }
        let start = base.addingTimeInterval(Double(nudgeMs) / 1_000)
        var placed = LiveSessionAlignment.place(session.margins, recordingStart: start, durationMs: transcript.durationMs.map { $0 + 1 })
        // Then each remaining Margin's own words as a hint ("Johnny was just talking about the budget"), searched
        // only near where the estimate puts it.
        for margin in placed where matches[margin.id] == nil && setAside[margin.id] == nil {
            guard let source = session.margins.first(where: { $0.id == margin.id }), !source.isBlindMark || !source.text.isEmpty,
                  let cue = hintCue(for: source.text, near: margin.offsetMs, in: transcript.cues, windowMs: window, threshold: hintThreshold)
            else { continue }
            matches[margin.id] = cue.index
            scores[margin.id] = cue.confidence
        }
        for index in placed.indices {
            let id = placed[index].id
            let source = session.margins.first { $0.id == id }
            placed[index].estimateMs = placed[index].offsetMs
            placed[index].listenerMs = source?.listenerPositionMs
            if let cue = matches[id] ?? setAside[id] {
                placed[index].matchMs = transcript.cues[cue].startMs
                placed[index].matchText = transcript.cues[cue].text
                placed[index].matchSpeaker = transcript.cues[cue].speaker
                placed[index].matchScore = scores[id]
            }
            // The listener's own setting is never overridden by a match that disagrees with it.
            if let cue = matches[id], let listener = placed[index].listenerMs, abs(transcript.cues[cue].startMs - listener) > window {
                matches[id] = nil
                setAside[id] = cue
            }
            let best = LiveSessionAlignment.best(
                estimateMs: placed[index].offsetMs, listenerMs: placed[index].listenerMs, matchMs: matches[id].map { transcript.cues[$0].startMs }
            )
            placed[index].offsetMs = best.offsetMs
            placed[index].source = best.source
            if best.source != .estimate { placed[index].clamp = nil }
        }
        return Result(transcriptStart: start, method: method, matches: matches, setAside: setAside, placed: placed)
    }

    /// How far from the estimate a hint is searched: ±10 minutes, or ±20 without an end position.
    public static let hintWindowMs = 600_000
    public static let hintWindowWithoutEndMs = 1_200_000
    public static let hintThreshold = 0.6

    private static let hintStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "about", "from",
        "i", "me", "my", "we", "us", "our", "you", "he", "she", "they", "them", "it", "its", "this", "that", "these",
        "those", "is", "are", "was", "were", "be", "been", "being", "am", "just", "now", "so", "very", "really",
        "think", "thought", "talking", "talked", "talk", "said", "saying", "says", "say", "mentioned", "mention",
        "something", "someone", "thing", "things", "here", "there", "then", "when", "what", "who", "like", "also"
    ]

    /// The cue near `estimateMs` that a Margin's own words point at: a speaker named in them and topic words in
    /// the cue. Confidence is 0.4 for the speaker plus 0.6 × the share of topic words the cue holds; with no
    /// speaker named, 0.8 × that share and at least two topic words. Below `threshold` there's no match, and
    /// among near-equal matches the one nearest the estimate wins.
    public static func hintCue(
        for text: String, near estimateMs: Int, in cues: [TranscriptCue], windowMs: Int, threshold: Double = hintThreshold
    ) -> (index: Int, confidence: Double)? {
        let speakerTokens = Set(cues.compactMap(\.speaker).flatMap { tokens($0) }.filter { $0.count >= 3 })
        let content = Set(tokens(text).filter { !hintStopwords.contains($0) })
        let named = content.intersection(speakerTokens)
        let topic = content.subtracting(speakerTokens)
        guard !topic.isEmpty else { return nil }
        var scored: [(index: Int, confidence: Double)] = []
        for (index, cue) in cues.enumerated() where abs(cue.startMs - estimateMs) <= windowMs {
            let cueWords = Set(tokens(cue.text))
            let found = topic.filter { cueWords.contains($0) }.count
            guard found > 0 else { continue }
            let share = Double(found) / Double(topic.count)
            let speakerHit = !named.isEmpty && !named.isDisjoint(with: Set(tokens(cue.speaker ?? "")))
            let confidence: Double
            if speakerHit {
                confidence = 0.4 + 0.6 * share
            } else {
                guard found >= 2 else { continue }
                confidence = 0.8 * share
            }
            if confidence >= threshold { scored.append((index, confidence)) }
        }
        guard let top = scored.map(\.confidence).max() else { return nil }
        return scored
            .filter { $0.confidence >= top - 0.05 }
            .min { abs(cues[$0.index].startMs - estimateMs) < abs(cues[$1.index].startMs - estimateMs) }
    }

    /// The cue (or the cue that starts a run of up to three) whose words best cover `text`. Only distinctive
    /// words count, each once: common words ("the", "is", "talking") would let any Margin match an opening
    /// line (#2485 audit), and speakers' names are left to `hintCue`. A match needs at least three of them and
    /// `threshold` of them found; ties go to the earlier cue.
    public static func bestCue(for text: String, in cues: [TranscriptCue], threshold: Double = 0.6) -> (index: Int, score: Double)? {
        // A speaker's name is the hint's evidence (`hintCue`), not words said aloud.
        let speakers = Set(cues.compactMap(\.speaker).flatMap { tokens($0) })
        let wanted = distinctiveWords(text).subtracting(speakers)
        guard wanted.count >= 3 else { return nil }
        let cueTokens = cues.map { Set(tokens($0.text)) }
        // Single cues first, then runs of two and three: a run wins only when it covers more of the words, so a
        // quote within one cue lands on that cue, not on a run that happens to include it.
        var best: (index: Int, score: Double, size: Int)?
        for size in 1...3 {
            for start in cues.indices where start + size <= cues.count {
                let run = (start..<(start + size)).map { cueTokens[$0] }
                // Every cue in a run must add words, or the shorter run already says it.
                guard size == 1 || run.allSatisfy({ !wanted.isDisjoint(with: $0) }) else { continue }
                let window = run.reduce(into: Set<String>()) { $0.formUnion($1) }
                let score = Double(wanted.filter { window.contains($0) }.count) / Double(wanted.count)
                if score >= threshold, score > (best?.score ?? 0) + 1e-9 { best = (start, score, size) }
            }
        }
        return best.map { ($0.index, $0.score) }
    }

    /// The words of `text` that can tell one cue from another: each once, without common words.
    static func distinctiveWords(_ text: String) -> Set<String> {
        Set(tokens(text).filter { !hintStopwords.contains($0) })
    }

    /// Lowercased words with accents and punctuation removed. A contraction keeps its stem ("let's" → "let",
    /// "I'm" → "i"), so it matches the word written out.
    public static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { word in
                let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard let apostrophe = trimmed.lastIndex(of: "'"),
                      contractionEndings.contains(String(trimmed[trimmed.index(after: apostrophe)...])) else { return trimmed }
                return String(trimmed[..<apostrophe])
            }
            .filter { !$0.isEmpty }
    }

    private static let contractionEndings: Set<String> = ["s", "m", "re", "ll", "ve", "d"]

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
            let estimate = LiveSessionPositionMap.position(at: margin.markedAt, in: session)
            if let estimate { line += ", at \(estimate.label)" }
            if let listener = margin.listenerPositionMs { line += ", you set \(clock(listener))" }
            if let note = margin.whereNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                line += ", \(note) or so"
            }
            text += line + "."
            var entry = LiveSessionAlignment.Placed(id: margin.id, text: margin.savedText, offsetMs: margin.sessionOffsetMs, charOffset: offset)
            entry.estimateMs = estimate?.ms
            entry.listenerMs = margin.listenerPositionMs
            entry.audioPath = margin.audioPath
            entry.transcript = margin.spokenTranscript
            let best = LiveSessionAlignment.best(estimateMs: estimate?.ms ?? margin.sessionOffsetMs, listenerMs: margin.listenerPositionMs, matchMs: nil)
            entry.offsetMs = best.offsetMs
            entry.source = best.source
            placed.append(entry)
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
