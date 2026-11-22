import Foundation

/// The words a transcript item adds to the item screen (#2997): one line under the title saying when the meeting was,
/// how long it ran and who spoke. Pure, so each case is host-tested.
public enum TranscriptItemWording {
    /// "Meeting on Thu 12 Nov, 15:00 · 48 min · Priya Patel, Sam Lee and 2 others".
    /// - `start`: the meeting's date and time, when the file or its name says. Wins over `timeOfDaySeconds`.
    /// - `timeOfDaySeconds`: seconds after midnight, for a file with a clock but no date (Zoom's saved captions).
    ///   The clock is read as written, never moved to another time zone.
    /// - `speakers`: in order of first appearance. One or two are named; three or more name two and count the rest.
    /// A part with nothing to say is left out, so "Meeting · 48 min" is the least a line says.
    public static func meetingLine(
        start: Date?,
        timeOfDaySeconds: Int?,
        durationMs: Int?,
        speakers: [String],
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var parts: [String] = []
        if let start {
            parts.append("Meeting on " + TranscriptItemText.meetingDateText(start, now: now, locale: locale, timeZone: timeZone))
        } else if let timeOfDaySeconds, (0..<86_400).contains(timeOfDaySeconds) {
            parts.append("Meeting at " + clockText(secondsAfterMidnight: timeOfDaySeconds, locale: locale))
        } else {
            parts.append("Meeting")
        }
        if let durationMs { parts.append(lengthText(durationMs: durationMs)) }
        if let names = speakersText(speakers) { parts.append(names) }
        return parts.joined(separator: " · ")
    }

    /// "under 1 min", "48 min", "1 h" or "1 h 12 min". Whole minutes are counted down, so a meeting never reads longer
    /// than it ran.
    public static func lengthText(durationMs: Int) -> String {
        guard durationMs >= 60_000 else { return "under 1 min" }
        let minutes = durationMs / 60_000
        guard minutes >= 60 else { return "\(minutes) min" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(remainder) min"
    }

    /// "Priya Patel", "Priya Patel and Sam Lee", "Priya Patel, Sam Lee and 2 others"; nil with no one named. Blank names
    /// and repeats are dropped.
    public static func speakersText(_ speakers: [String]) -> String? {
        var seen = Set<String>()
        var names: [String] = []
        for speaker in speakers {
            let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
        }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let others = names.count - 2
            return "\(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
    }

    private static func clockText(secondsAfterMidnight: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(secondsAfterMidnight)))
    }
}

/// Where in the meeting a Margin was made (#2997).
public enum TranscriptMeetingClock {
    /// The start of the last cue that begins at or before `character`, or nil when the text is empty or `character`
    /// comes before every cue. `cueStartChars` is increasing and `cueStartMs` runs alongside it, as the item's times
    /// record keeps them. A Margin on the blank line between two paragraphs belongs to the paragraph before it; one
    /// inside a speaker's name belongs to the cue that starts the paragraph, which begins at the name.
    public static func clockMs(atCharacter character: Int, cueStartChars: [Int], cueStartMs: [Int]) -> Int? {
        let count = min(cueStartChars.count, cueStartMs.count)
        guard count > 0, character >= cueStartChars[0] else { return nil }
        var low = 0, high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if cueStartChars[middle] <= character { low = middle } else { high = middle - 1 }
        }
        return cueStartMs[low]
    }

    public static func clockMs(atCharacter character: Int, cues: [TranscriptItemCue]) -> Int? {
        clockMs(atCharacter: character, cueStartChars: cues.map(\.startChar), cueStartMs: cues.map(\.startMs))
    }
}
