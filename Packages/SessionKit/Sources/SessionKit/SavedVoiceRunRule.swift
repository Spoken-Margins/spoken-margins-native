import Foundation

/// While the bundled voice holds narration on a hot phone (#849), when saved Supertonic audio ahead plays instead
/// (#1680). Owner's call (2026-10-15): yes, "as long as we aren't bouncing back and forth". So the voice changes to
/// saved Supertonic only at a paragraph seam (or where the play starts), only for a saved run long enough to be worth
/// it, and stays there to the end of that run: at most one change each way per run, never a short Supertonic island
/// inside the bundled voice.
public enum SavedVoiceRunRule {
    /// The listening a saved run must cover from its seam, unless it runs to the end of the item.
    public static let minimumListening: TimeInterval = 5 * 60

    public enum Choice: Equatable, Sendable {
        case savedSupertonic
        case bundledVoice
    }

    /// - Parameters:
    ///   - inSavedRun: an earlier chunk switched to a saved run that hasn't ended.
    ///   - atSeam: the chunk starts a paragraph, or the play starts here.
    ///   - savedRun: the saved Supertonic audio from this chunk on, in seconds per chunk, in plan order, up to the
    ///     first chunk without any. It may stop early once it is long enough.
    ///   - reachesEnd: `savedRun` covers every chunk to the end of the item.
    ///   - playbackRate: the listener's speed; five minutes of listening is more audio at a faster speed.
    public static func choice(
        inSavedRun: Bool, atSeam: Bool, savedRun: [TimeInterval], reachesEnd: Bool, playbackRate: Double
    ) -> Choice {
        guard let first = savedRun.first, first > 0 else { return .bundledVoice }
        if inSavedRun { return .savedSupertonic }
        guard atSeam else { return .bundledVoice }
        return isLongEnough(savedRun, reachesEnd: reachesEnd, playbackRate: playbackRate) ? .savedSupertonic : .bundledVoice
    }

    public static func isLongEnough(_ savedRun: [TimeInterval], reachesEnd: Bool, playbackRate: Double) -> Bool {
        guard !savedRun.isEmpty else { return false }
        if reachesEnd { return true }
        return savedRun.reduce(0, +) / max(0.25, playbackRate) >= minimumListening
    }

    /// Whether chunk `index` of a plan starts at a paragraph seam: the first sentence boundary after a paragraph
    /// break. The planner's chunks run across paragraph breaks and may end at a comma, so the voice changes only where
    /// the previous chunk ends a sentence, and only when a line break lies between the end of the sentence before and
    /// this chunk's first word. Chunk 0 is a seam. `sourceStart` gives a chunk's start in `text`, the source text (the
    /// spoken text has its line breaks turned into spaces); `endsSentence` whether a chunk ends a sentence.
    public static func isParagraphSeam(
        in text: String, at index: Int, sourceStart: (Int) -> Int, endsSentence: (Int) -> Bool
    ) -> Bool {
        guard index > 0 else { return true }
        guard endsSentence(index - 1) else { return false }
        var first = index - 1
        while first > 0, !endsSentence(first - 1) { first -= 1 }
        return isParagraphSeam(in: text, previousStart: sourceStart(first), start: sourceStart(index))
    }

    /// Whether a line break lies between `previousStart` and the first word at or after `start`, in `text`. With no
    /// previous start (the start of the text), it does.
    public static func isParagraphSeam(in text: String, previousStart: Int?, start: Int) -> Bool {
        guard let previousStart else { return true }
        guard previousStart >= 0, previousStart < start,
              let from = text.index(text.startIndex, offsetBy: previousStart, limitedBy: text.endIndex),
              let to = text.index(from, offsetBy: start - previousStart, limitedBy: text.endIndex) else { return false }
        if text[from..<to].contains(where: \.isNewline) { return true }
        for character in text[to...] {
            guard character.isWhitespace else { return false }
            if character.isNewline { return true }
        }
        return false
    }
}
