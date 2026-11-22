#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where one cue's words begin in the item's text (#2997).
public struct TranscriptItemCue: Equatable, Sendable {
    /// A Swift `Character` offset into `TranscriptItemText.text`, as in `LiveSessionText` and `MarginPlaceIndex`.
    public var startChar: Int
    public var startMs: Int
    public var endMs: Int?
    public var speaker: String?

    public init(startChar: Int, startMs: Int, endMs: Int?, speaker: String?) {
        self.startChar = startChar
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

/// A transcript turned into the text a listener hears and anchors Margins to. The same file gives byte-identical
/// text, and so the same id, on every phone and every build: the item id and a packet's digests come from it, so
/// changing `build` once it ships is a compatibility change (`TranscriptItemTextTests` pins the ids).
public struct TranscriptItemText: Equatable, Sendable {
    public var id: String
    public var title: String
    public var meetingStart: Date?
    public var text: String
    public var cues: [TranscriptItemCue]

    /// The `externalReferenceType` of an item made from a transcript file. The item is ordinary text (`mediaType`
    /// "text"); this marks it for its Library label, noun, meeting line and Margin clocks.
    public static let referenceType = "transcript"

    /// A paragraph also ends before the first cue that starts this long after the paragraph's first cue.
    public static let paragraphSpanMs = 60_000

    /// One paragraph per speaker turn, written "Speaker: words", with a turn's cues joined by one space and
    /// paragraphs separated by a blank line. A change of speaker starts a paragraph; cues with no speaker form a
    /// turn of their own with no name. A turn also breaks every minute, and the continuation carries no name.
    /// Timestamps are never written into the text.
    public static func build(_ transcript: ImportedTranscript, fileName: String, timeZone: TimeZone = .current) -> TranscriptItemText {
        struct Paragraph {
            var prefix: String
            var firstStartMs: Int
            var startScalar: Int
            var pieces: [String] = []
            /// Unicode scalars of the pieces joined by single spaces.
            var wordsLength = 0
        }
        var paragraphs: [Paragraph] = []
        var cueStarts: [(scalar: Int, cue: TranscriptCue, speaker: String?)] = []
        var turnSpeaker: String?
        var haveTurn = false
        var runningCount = 0

        // Offsets are summed in Unicode scalars as pieces are added, then turned into `Character` offsets in one pass
        // over the finished text, so building stays linear in the file's size and a piece that begins with a
        // combining mark (which merges into the space before it) can't shift the offsets after it.
        for cue in transcript.cues {
            let words = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            let speaker = cue.speaker?.precomposedStringWithCanonicalMapping
            let newTurn = !haveTurn || turnSpeaker != speaker
            let tooLong = paragraphs.last.map { cue.startMs - $0.firstStartMs >= paragraphSpanMs } ?? false
            if newTurn || tooLong {
                if let last = paragraphs.last { runningCount += last.prefix.unicodeScalars.count + last.wordsLength + 2 }
                let prefix = newTurn ? speaker.map { "\($0): " } ?? "" : ""
                paragraphs.append(Paragraph(prefix: prefix, firstStartMs: cue.startMs, startScalar: runningCount))
                turnSpeaker = speaker
                haveTurn = true
            }
            let last = paragraphs.count - 1
            let start = paragraphs[last].pieces.isEmpty
                ? paragraphs[last].startScalar
                : paragraphs[last].startScalar + paragraphs[last].prefix.unicodeScalars.count + paragraphs[last].wordsLength + 1
            paragraphs[last].wordsLength += (paragraphs[last].pieces.isEmpty ? 0 : 1) + words.unicodeScalars.count
            paragraphs[last].pieces.append(words)
            cueStarts.append((start, cue, speaker))
        }

        let text = paragraphs.map { $0.prefix + $0.pieces.joined(separator: " ") }.joined(separator: "\n\n")
        // Scalar offsets are increasing, so one walk over the characters places every cue.
        var cues: [TranscriptItemCue] = []
        cues.reserveCapacity(cueStarts.count)
        var next = 0
        var scalarsBefore = 0
        var characterIndex = 0
        for character in text {
            let width = character.unicodeScalars.count
            while next < cueStarts.count, cueStarts[next].scalar < scalarsBefore + width {
                let source = cueStarts[next]
                cues.append(TranscriptItemCue(startChar: characterIndex, startMs: source.cue.startMs, endMs: source.cue.endMs, speaker: source.speaker))
                next += 1
            }
            scalarsBefore += width
            characterIndex += 1
        }
        let zoomStart = zoomStartDate(inFileName: fileName)
        return TranscriptItemText(
            id: "item-transcript-" + digestPrefix(of: text),
            title: title(for: transcript, fileName: fileName, zoomStart: zoomStart, timeZone: timeZone),
            meetingStart: transcript.absoluteStart ?? zoomStart,
            text: text,
            cues: cues
        )
    }

    /// The first 24 hex characters of the SHA-256 of the text's UTF-8 bytes.
    static func digestPrefix(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    // MARK: Title

    /// The first that applies: the transcript's header title; "Meeting on ‹date›" for a Zoom file name; the file
    /// name without its extensions; "Meeting transcript".
    static func title(for transcript: ImportedTranscript, fileName: String, zoomStart: Date?, timeZone: TimeZone, now: Date = Date()) -> String {
        if let header = transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty { return header }
        if let zoomStart { return "Meeting on " + meetingDateText(zoomStart, now: now, timeZone: timeZone) }
        let base = nameWithoutExtensions(fileName)
        return base.isEmpty ? "Meeting transcript" : base
    }

    /// "Budget sync.transcript.vtt" → "Budget sync". Only the format's own extension and a following ".transcript"
    /// go, so "Q3 review.v2.vtt" keeps "Q3 review.v2".
    static func nameWithoutExtensions(_ fileName: String) -> String {
        var name = (fileName as NSString).lastPathComponent
        for suffix in [".vtt", ".srt", ".txt", ".docx", ".text"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        if name.lowercased().hasSuffix(".transcript") { name = String(name.dropLast(".transcript".count)) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zoom names its files `GMT20261112-150000_Recording.transcript.vtt`; the stamp is in GMT.
    static func zoomStartDate(inFileName fileName: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"GMT(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})"#),
              let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) else { return nil }
        let numbers = (1...6).compactMap { index in Range(match.range(at: index), in: fileName).flatMap { Int(fileName[$0]) } }
        guard numbers.count == 6 else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (numbers[0], numbers[1], numbers[2])
        (components.hour, components.minute, components.second) = (numbers[3], numbers[4], numbers[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // The calendar rolls an impossible date (month 13, 25:61:00) into a wrong one; refuse it instead.
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard [back.year, back.month, back.day, back.hour, back.minute, back.second] == numbers else { return nil }
        return date
    }

    /// The meeting line's date: the locale's weekday, day, month and time, with the year added when it isn't this year.
    public static func meetingDateText(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMMjmm" : "EEEdMMMyjmm")
        return formatter.string(from: date)
    }
}
