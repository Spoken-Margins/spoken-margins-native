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

    /// Whether the chunk starting at `start` is a paragraph seam: the first chunk boundary after a paragraph break,
    /// that is, a line break lies between the previous chunk's start (`previousStart`) and this chunk's first word.
    /// The planner's chunks run across paragraph breaks, so a boundary rarely sits exactly on one; this one is the
    /// nearest after it. With no previous chunk (the start of the text), it is a seam. `text` and the offsets are the
    /// source text's: the spoken text has its line breaks turned into spaces.
    public static func isParagraphSeam(in text: String, previousStart: Int?, start: Int) -> Bool {
        guard let previousStart else { return true }
        let characters = Array(text)
        guard previousStart >= 0, previousStart < start, start <= characters.count else { return false }
        if characters[previousStart..<start].contains(where: \.isNewline) { return true }
        var index = start
        while index < characters.count, characters[index].isWhitespace {
            if characters[index].isNewline { return true }
            index += 1
        }
        return false
    }
}
