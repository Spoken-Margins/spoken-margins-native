import Foundation

/// The Test Desk's Share Margins seed (#4647 PR 0): five of the listener's own spoken Margins with fillers to remove and
/// two long pauses each, so a simulator can show and time the cleanup and the wait. Only a Debug UI-test launch with
/// `SPOKEN_MARGINS_UI_TEST_SHARE_BATCH=1` uses it; the app writes the matching recordings.
public enum ShareBatchSeed {
    public static let marginCount = 5
    public static let lineCount = 25
    /// Each word lasts this long, laid end to end.
    public static let wordMs = 300
    /// Two silent gaps, each this long, a third and two thirds of the way through.
    public static let gapMs = 1_200
    /// Margins 2 and 4 are starred, so the chips have something to show.
    public static let starredMargins: Set<Int> = [2, 4]

    public static func id(margin: Int) -> String {
        "ij-ui-share-batch-\(margin)"
    }

    /// About 25 lines of words with "um" and "uh" in them.
    public static func words(margin: Int) -> [String] {
        (1...lineCount).flatMap { line -> [String] in
            let filler = line.isMultiple(of: 2) ? "uh" : "um"
            return ["Line", "\(line)", "of", "Margin", "\(margin),", filler, "the", "harbour", "light", "turns."]
        }
    }

    public static func text(margin: Int) -> String {
        words(margin: margin).joined(separator: " ")
    }

    /// Where the two gaps start: after these word indexes.
    public static func gapsAfter(wordCount: Int) -> Set<Int> {
        [wordCount / 3 - 1, (2 * wordCount) / 3 - 1]
    }

    /// The words' timing: end to end at `wordMs`, with a `gapMs` silence after each gap word.
    public static func transcript(margin: Int) -> AlignedInterjectionTranscript {
        let words = words(margin: margin)
        let gaps = gapsAfter(wordCount: words.count)
        var start = 0
        var segments: [AlignedTranscriptSegment] = []
        for (index, word) in words.enumerated() {
            segments.append(AlignedTranscriptSegment(
                id: "\(id(margin: margin))-w\(index)", text: word, startMs: start, endMs: start + wordMs))
            start += wordMs
            if gaps.contains(index) { start += gapMs }
        }
        return AlignedInterjectionTranscript(text: text(margin: margin), localeIdentifier: "en-US", segments: segments)
    }

    /// The recording's length: every word and both gaps.
    public static func durationMs(margin: Int) -> Int {
        transcript(margin: margin).segments.last?.endMs ?? 0
    }

    /// Whether the tone sounds at this moment, or it is one of the gaps (digital silence).
    public static func isVoiced(atMs ms: Int, margin: Int) -> Bool {
        transcript(margin: margin).segments.contains { ms >= $0.startMs && ms < $0.endMs }
    }
}
