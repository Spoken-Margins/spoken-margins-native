import Foundation

/// What a transcript item keeps of its meeting's clock (#2997): the summary the item screen's meeting line reads, and
/// where each cue starts in the item's text and in the meeting. Stored in its own `transcript_times` record, keyed by
/// the item id, and not as `Item` fields, because a build that rewrites the item would drop fields it doesn't know.
/// A build without this record ignores it.
///
/// The payload is two integer arrays and a short summary, with no cue text and no per-cue speaker, so a three-hour
/// meeting of 10,000 cues stays a few tens of kilobytes and decodes in milliseconds.
public struct TranscriptTimes: Codable, Equatable, Sendable {
    /// The store's record kind.
    public static let recordKind = "transcript_times"

    public struct Summary: Codable, Equatable, Sendable {
        /// The meeting's date and time, when the file or its Zoom file name says.
        public var meetingStart: Date?
        /// Seconds after midnight, for a file with a clock and no date (Zoom's saved captions).
        public var startTimeOfDaySeconds: Int?
        public var durationMs: Int?
        /// In order of first appearance.
        public var speakers: [String]

        public init(meetingStart: Date? = nil, startTimeOfDaySeconds: Int? = nil, durationMs: Int? = nil, speakers: [String] = []) {
            self.meetingStart = meetingStart
            self.startTimeOfDaySeconds = startTimeOfDaySeconds
            self.durationMs = durationMs
            self.speakers = speakers
        }
    }

    public var itemId: String
    /// `ImportedTranscript.Format`'s raw value: "webVTT", "srt" or "plainText".
    public var format: String
    public var summary: Summary
    /// A `Character` offset into the item's text for each cue, increasing.
    public var cueStartChars: [Int]
    /// Where each cue starts in the meeting, in ms from the transcript's time zero, alongside `cueStartChars`.
    public var cueStartMs: [Int]

    public init(itemId: String, format: String, summary: Summary, cueStartChars: [Int], cueStartMs: [Int]) {
        self.itemId = itemId
        self.format = format
        self.summary = summary
        self.cueStartChars = cueStartChars
        self.cueStartMs = cueStartMs
    }

    /// The times of the item `built` made from `transcript`.
    public init(transcript: ImportedTranscript, built: TranscriptItemText) {
        var seen = Set<String>()
        var speakers: [String] = []
        for cue in built.cues {
            if let speaker = cue.speaker, !speaker.isEmpty, seen.insert(speaker).inserted { speakers.append(speaker) }
        }
        self.init(
            itemId: built.id,
            format: transcript.format.rawValue,
            summary: Summary(
                meetingStart: built.meetingStart, startTimeOfDaySeconds: transcript.startTimeOfDaySeconds,
                durationMs: transcript.durationMs, speakers: speakers),
            cueStartChars: built.cues.map(\.startChar),
            cueStartMs: built.cues.map(\.startMs))
    }

    /// Where in the meeting a Margin at `character` was made, in ms; nil before the first cue.
    public func clockMs(atCharacter character: Int) -> Int? {
        TranscriptMeetingClock.clockMs(atCharacter: character, cueStartChars: cueStartChars, cueStartMs: cueStartMs)
    }

    /// The item screen's line under the title.
    public func meetingLine(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        TranscriptItemWording.meetingLine(
            start: summary.meetingStart, timeOfDaySeconds: summary.startTimeOfDaySeconds, durationMs: summary.durationMs,
            speakers: summary.speakers, now: now, locale: locale, timeZone: timeZone)
    }
}
