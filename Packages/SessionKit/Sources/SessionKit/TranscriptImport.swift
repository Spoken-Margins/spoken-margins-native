import Foundation

/// One line of a meeting transcript: when it was said, by whom, and what.
public struct TranscriptCue: Codable, Equatable, Sendable {
    /// From the transcript's time zero (the recording's start, or the first cue for wall-clock formats).
    public var startMs: Int
    public var endMs: Int?
    public var speaker: String?
    public var text: String

    public init(startMs: Int, endMs: Int? = nil, speaker: String? = nil, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }
}

/// A meeting transcript in one normalized shape, whatever the file was (#2481).
public struct ImportedTranscript: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Equatable, Sendable {
        case webVTT
        case srt
        /// Speaker and timestamp lines: Teams .docx, Otter, Google Meet, Zoom saved captions.
        case plainText
    }

    public var format: Format
    public var cues: [TranscriptCue]
    /// The wall-clock moment of time zero, when the file says (Meet's title line, a Teams or Otter header).
    public var absoluteStart: Date?
    /// For wall-clock formats with no date (Zoom's saved captions): the time of day of time zero, in seconds
    /// after midnight. The date comes from the session.
    public var startTimeOfDaySeconds: Int?
    /// A title from the file's header, when it has one.
    public var title: String?

    public init(format: Format, cues: [TranscriptCue], absoluteStart: Date? = nil, startTimeOfDaySeconds: Int? = nil, title: String? = nil) {
        self.format = format
        self.cues = cues
        self.absoluteStart = absoluteStart
        self.startTimeOfDaySeconds = startTimeOfDaySeconds
        self.title = title
    }

    public var durationMs: Int? {
        guard let last = cues.last else { return nil }
        return last.endMs ?? last.startMs
    }
}

/// Reads WebVTT, SRT and speaker/timestamp plain text into `ImportedTranscript`. The format is found from the
/// content, not the file name, and the reader is lenient: a BOM, CRLF, unpadded times (`0:0:3.48`), comma or
/// dot milliseconds, `m:ss` rolling to `h:mm:ss`, Teams' `0 minutes 3 seconds`, cue ids, header blocks and a
/// missing speaker are all accepted. A cue without an end time ends where the next one starts.
public enum TranscriptImport {
    public enum Failure: Error, Equatable, LocalizedError {
        case empty
        case noCues

        public var errorDescription: String? {
            switch self {
            case .empty: "The transcript file is empty."
            case .noCues: "No timed lines were found. Choose a .vtt, .srt, or a text or Word transcript with timestamps."
            }
        }
    }

    public static func parse(data: Data, timeZone: TimeZone = .current) throws -> ImportedTranscript {
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text: text, timeZone: timeZone)
    }

    public static func parse(text raw: String, timeZone: TimeZone = .current) throws -> ImportedTranscript {
        let text = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        let lines = text.components(separatedBy: "\n")
        var transcript: ImportedTranscript
        if lines.contains(where: { timingLine($0) != nil }) {
            let isVTT = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.hasPrefix("WEBVTT") == true
            transcript = ImportedTranscript(format: isVTT ? .webVTT : .srt, cues: parseCueBlocks(lines))
        } else {
            transcript = parsePlain(lines, timeZone: timeZone)
        }
        transcript.cues = fillEnds(transcript.cues.filter { !$0.text.isEmpty })
        guard !transcript.cues.isEmpty else { throw Failure.noCues }
        return transcript
    }

    // MARK: Times

    /// `0:0:3.48`, `00:00:03.500`, `00:00:03,500`, `3:05`, `1:02:03`. Returns milliseconds.
    static func clockMs(_ token: String) -> Int? {
        let parts = token.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts.last!.replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart), seconds >= 0, seconds < 60 else { return nil }
        var whole: [Int] = []
        for part in parts.dropLast() {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            whole.append(value)
        }
        if whole.count == 2, whole[1] >= 60 { return nil }
        let hours = whole.count == 2 ? whole[0] : 0
        let minutes = whole.count == 2 ? whole[1] : whole[0]
        return (hours * 3_600 + minutes * 60) * 1_000 + Int((seconds * 1_000).rounded())
    }

    /// Teams .docx: `0 minutes 3 seconds`, `1 hour 2 minutes 3 seconds`, `45 seconds`.
    static func spelledMs(_ token: String) -> Int? {
        let pattern = #"^\s*(?:(\d+)\s+hours?\s*)?(?:(\d+)\s+minutes?\s*)?(?:(\d+)\s+seconds?)\s*$"#
        guard let match = firstMatch(pattern, in: token) else { return nil }
        let value = { (index: Int) -> Int in match[index].flatMap { Int($0) } ?? 0 }
        return (value(1) * 3_600 + value(2) * 60 + value(3)) * 1_000
    }

    static func timingLine(_ line: String) -> (start: Int, end: Int)? {
        let pieces = line.components(separatedBy: "-->")
        guard pieces.count == 2,
              let start = clockMs(pieces[0]),
              let endToken = pieces[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = clockMs(String(endToken)) else { return nil }
        return (start, end)
    }

    // MARK: WebVTT and SRT

    private static func parseCueBlocks(_ lines: [String]) -> [TranscriptCue] {
        var cues: [TranscriptCue] = []
        var index = 0
        while index < lines.count {
            guard let timing = timingLine(lines[index]) else { index += 1; continue }
            var payload: [String] = []
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                // A missing blank line before the next cue: stop at its timing line (and drop its id).
                if timingLine(lines[index]) != nil {
                    if !payload.isEmpty { payload.removeLast() }
                    break
                }
                payload.append(lines[index])
                index += 1
            }
            let (speaker, text) = speakerAndText(payload.joined(separator: " "))
            cues.append(TranscriptCue(startMs: timing.start, endMs: timing.end, speaker: speaker, text: text))
        }
        return cues
    }

    /// Takes the speaker from a `<v Name>` voice tag or a short `Name:` prefix, and strips markup.
    static func speakerAndText(_ payload: String) -> (String?, String) {
        var speaker: String?
        if let match = firstMatch(#"<v(?:\.[^\s>]+)*\s+([^>]+)>"#, in: payload) {
            speaker = match[1]?.trimmingCharacters(in: .whitespaces)
        }
        var text = payload.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        text = decodeEntities(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if speaker == nil, let (name, rest) = namePrefix(text) {
            speaker = name
            text = rest
        }
        return (speaker, text)
    }

    /// `Alice Example: Welcome…` → ("Alice Example", "Welcome…"). Only a short name-like prefix counts, so a
    /// sentence such as "Note: the budget is late" from someone unnamed stays text when it reads like prose.
    static func namePrefix(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces)
        let afterColon = text.index(after: colon)
        // "Name: text" has a space after the colon; "3:2" and "10:30" don't.
        guard afterColon < text.endIndex, text[afterColon] == " " else { return nil }
        let rest = text[afterColon...].trimmingCharacters(in: .whitespaces)
        let words = name.split(separator: " ")
        guard !name.isEmpty, !rest.isEmpty, name.count <= 40, (1...5).contains(words.count),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!,;\"")) == nil,
              !name.allSatisfy({ $0.isNumber || $0 == ":" }),
              rest.first != "/" // a URL's "https://"
        else { return nil }
        return (name, rest)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    // MARK: Plain text

    private enum Header {
        /// A cue start: an optional speaker and a time from the transcript's zero.
        case relative(speaker: String?, ms: Int)
        /// Zoom's saved captions: `[Name] 10:00:03`, a time of day.
        case wallClock(speaker: String?, secondsOfDay: Int)
    }

    private static func header(_ rawLine: String) -> Header? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        // [Alice Example] 10:00:03
        if let match = firstMatch(#"^\[([^\]]+)\]\s+(\d{1,2}:\d{2}:\d{2})$"#, in: line), let ms = clockMs(match[2] ?? "") {
            return .wallClock(speaker: match[1], secondsOfDay: ms / 1_000)
        }
        // 00:00:03  (a bare time line; the speaker is on the next line)
        if let ms = clockMs(line), line.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." || $0 == "," }) {
            return .relative(speaker: nil, ms: ms)
        }
        // Alice Example  0:03   /   Alice Example   0 minutes 3 seconds   (two or more spaces, or a tab)
        if let match = firstMatch(#"^(.+?)(?:\s{2,}|\t+)(\S.*)$"#, in: rawLine.trimmingCharacters(in: .whitespaces)),
           let name = match[1], let time = match[2] {
            if let ms = clockMs(time) ?? spelledMs(time), name.count <= 60 {
                return .relative(speaker: name.trimmingCharacters(in: .whitespaces), ms: ms)
            }
        }
        // 0:03 Alice Example: text  is rare; leave it to the text path.
        return nil
    }

    private static func parsePlain(_ lines: [String], timeZone: TimeZone) -> ImportedTranscript {
        var cues: [TranscriptCue] = []
        var headerLines: [String] = []
        var current: TranscriptCue?
        var wallClockOrigin: Int?
        var sawCue = false

        func flush() {
            if var cue = current {
                cue.text = cue.text.trimmingCharacters(in: .whitespaces)
                if !cue.text.isEmpty { cues.append(cue) }
            }
            current = nil
        }

        for line in lines {
            if let header = header(line) {
                flush()
                sawCue = true
                switch header {
                case let .relative(speaker, ms):
                    current = TranscriptCue(startMs: ms, speaker: speaker, text: "")
                case let .wallClock(speaker, seconds):
                    let origin = wallClockOrigin ?? seconds
                    wallClockOrigin = origin
                    var elapsed = seconds - origin
                    if elapsed < 0 { elapsed += 86_400 } // past midnight
                    current = TranscriptCue(startMs: elapsed * 1_000, speaker: speaker, text: "")
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard sawCue else {
                headerLines.append(trimmed)
                continue
            }
            guard !trimmed.isEmpty else { continue }
            guard var cue = current else {
                // Text after a finished cue with no new time: a new line from the last time.
                if let last = cues.last {
                    let (speaker, text) = namePrefix(trimmed).map { ($0.0 as String?, $0.1) } ?? (last.speaker, trimmed)
                    current = TranscriptCue(startMs: last.startMs, speaker: speaker, text: text)
                }
                continue
            }
            if cue.text.isEmpty, cue.speaker == nil, let (name, rest) = namePrefix(trimmed) {
                cue.speaker = name
                cue.text = rest
            } else {
                cue.text += (cue.text.isEmpty ? "" : " ") + trimmed
            }
            current = cue
        }
        flush()
        let headerInfo = parseHeader(headerLines.filter { !$0.isEmpty }, timeZone: timeZone)
        return ImportedTranscript(
            format: .plainText,
            cues: cues.sorted { $0.startMs < $1.startMs },
            absoluteStart: wallClockOrigin == nil ? headerInfo.date : nil,
            startTimeOfDaySeconds: wallClockOrigin,
            title: headerInfo.title
        )
    }

    /// Finds a meeting date in a header block: Meet's `Title - 2026/03/04 10:00 GMT - Transcript`, Otter's
    /// `Mar 4, 2026 10:00 AM`, Teams' `March 4, 2026, 10:00AM`.
    static func parseHeader(_ lines: [String], timeZone: TimeZone) -> (title: String?, date: Date?) {
        var date: Date?
        var title: String?
        for line in lines {
            if date == nil, let found = headerDate(line, timeZone: timeZone) {
                date = found
                if title == nil, line.contains(" - ") {
                    title = line.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if title == nil, date == nil, line.count <= 120 { title = line }
        }
        return (title, date)
    }

    static func headerDate(_ line: String, timeZone: TimeZone) -> Date? {
        // 2026/03/04 10:00 GMT
        if let match = firstMatch(#"(\d{4})/(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})(?:\s+([A-Za-z]{2,5}|[+-]\d{2}:?\d{2}))?"#, in: line) {
            var components = DateComponents()
            components.year = match[1].flatMap { Int($0) }
            components.month = match[2].flatMap { Int($0) }
            components.day = match[3].flatMap { Int($0) }
            components.hour = match[4].flatMap { Int($0) }
            components.minute = match[5].flatMap { Int($0) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = match[6].flatMap(zone(_:)) ?? timeZone
            return calendar.date(from: components)
        }
        // March 4, 2026, 10:00AM  /  Mar 4, 2026 10:00 AM
        if let match = firstMatch(#"([A-Z][a-z]{2,8})\.?\s+(\d{1,2}),\s*(\d{4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?"#, in: line) {
            let monthName = match[1] ?? ""
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: String(monthName.lowercased().prefix(3))) else { return nil }
            var hour = match[4].flatMap { Int($0) } ?? 0
            if let meridiem = match[7]?.lowercased() {
                if meridiem == "pm", hour < 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
            }
            var components = DateComponents()
            components.year = match[3].flatMap { Int($0) }
            components.month = month + 1
            components.day = match[2].flatMap { Int($0) }
            components.hour = hour
            components.minute = match[5].flatMap { Int($0) }
            components.second = match[6].flatMap { Int($0) } ?? 0
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(from: components)
        }
        return nil
    }

    private static func zone(_ token: String) -> TimeZone? {
        if token.uppercased() == "GMT" || token.uppercased() == "UTC" { return TimeZone(identifier: "UTC") }
        if let match = firstMatch(#"^([+-])(\d{2}):?(\d{2})$"#, in: token) {
            let sign = match[1] == "-" ? -1 : 1
            let seconds = ((match[2].flatMap { Int($0) } ?? 0) * 3_600 + (match[3].flatMap { Int($0) } ?? 0) * 60) * sign
            return TimeZone(secondsFromGMT: seconds)
        }
        return TimeZone(abbreviation: token.uppercased())
    }

    // MARK: Helpers

    private static func fillEnds(_ cues: [TranscriptCue]) -> [TranscriptCue] {
        var filled = cues
        for index in filled.indices where filled[index].endMs == nil {
            if index + 1 < filled.count, filled[index + 1].startMs > filled[index].startMs {
                filled[index].endMs = filled[index + 1].startMs
            }
        }
        return filled
    }

    /// The capture groups of the first match, nil where a group didn't take part.
    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
