import Foundation

/// The clock "Play this moment" counts its lead-in on (#1577).
///
/// `MarginMomentSequence` counts milliseconds. A podcast, or an article playing prepared narration, has a media
/// clock for that. An article read aloud on the device has none: playback only knows how far through the text it
/// is, and its Margins are anchored by text position. For that source the moment counts narration time instead,
/// the written characters read a second at 1× (`ListeningTimeEstimator.defaultCharactersPerSecond`), so the one
/// lead-in rule (`ListeningMoment`, #807) and the countdown work the same way on every kind of item.
public enum MarginMomentClock: Sendable, Equatable {
    /// Positions are the source's media time in milliseconds.
    case media
    /// Positions are text offsets read by on-device speech, converted to milliseconds of narration at 1×.
    case narratedText(charactersPerSecond: Double)

    /// An article read aloud on the device at the typical rate.
    public static let liveNarration = MarginMomentClock.narratedText(
        charactersPerSecond: ListeningTimeEstimator.defaultCharactersPerSecond
    )

    public var isNarratedText: Bool {
        if case .narratedText = self { return true }
        return false
    }

    /// The largest forward move between two progress readings that still counts as playback. On-device speech
    /// reports where it is a word at a time, so a text reading moves a few characters a tick: half a second at 3× is
    /// about 30 characters, 2 s of narration. 6 s (about 84 characters) covers a late tick and stays under a
    /// sentence skip, which must not play the Margin it jumps over (#1646). The app also tells the conductor about every
    /// skip and seek (`MarginMomentConductor.sourceMoved`), so a short skip is never taken for playback either.
    public var tickAdvanceLimitMs: Int {
        isNarratedText ? 6_000 : MarginMomentSequence.maxTickAdvanceMs
    }

    private var charactersPerSecond: Double {
        guard case let .narratedText(rate) = self, rate.isFinite, rate > 0 else {
            return ListeningTimeEstimator.defaultCharactersPerSecond
        }
        return rate
    }

    /// The text offset's place on this clock. Zero for a media clock, which has no text offsets.
    public func position(forTextOffset offset: Int) -> Int {
        guard isNarratedText else { return 0 }
        return Int((Double(max(0, offset)) / charactersPerSecond * 1_000).rounded())
    }

    /// The text offset at a place on this clock. Zero for a media clock.
    public func textOffset(forPosition ms: Int) -> Int {
        guard isNarratedText else { return 0 }
        return Int((Double(max(0, ms)) / 1_000 * charactersPerSecond).rounded())
    }

    /// Where a lead-in before the Margin at `targetPosition` starts reading: the first sentence start at or after the
    /// rule's start, so speech doesn't begin mid-sentence. It is the Margin's own place when no sentence starts
    /// between (#1646: the planner and the lead-in both use this, so they agree on which Margins fall in the gap).
    public func leadInStartOffset(forTargetPosition targetPosition: Int, in text: String) -> Int {
        let target = MarginMomentAnchor(marginId: "target", mediaTimeMs: targetPosition)
        let ruleStart = textOffset(forPosition: MarginMomentSequence.leadInStartMediaTimeMs(forTarget: target))
        return Self.sentenceStart(atOrAfter: ruleStart, before: textOffset(forPosition: targetPosition), in: text)
    }

    /// Where the lead-in should start reading: the first sentence start at or after `offset`, so speech doesn't
    /// begin mid-sentence. `offset` stays as it is when that start would reach `limit` (the Margin itself) or
    /// the text has none after it.
    ///
    /// A sentence ends at `.`, `!`, `?` or `…` (with any closing quote or bracket after it) followed by white space,
    /// except after an abbreviation (`Mr.`, `e.g.`, an initial) or before a lower-case word (`Wait... then`). A blank
    /// line ends one too, which is how a heading with no punctuation of its own ends. Initialisms (`U.S. Army`) and
    /// names with initials don't end one, unless a word that opens sentences follows (`Vitamin A. Then`).
    ///
    /// Only the stretch of text around `offset` is looked at (#2506): the text can be megabytes, and a sentence break
    /// is decided by a few characters on each side of it. The window starts `windowLookBehind` characters before
    /// `offset` and grows until it holds the answer, so a text with no break for a page still gets the same result as
    /// a scan from the start (`testWindowedSentenceStartMatchesAScanFromTheStart`).
    public static func sentenceStart(atOrAfter offset: Int, before limit: Int, in text: String) -> Int {
        sentenceStartScan(atOrAfter: offset, before: limit, in: text).start
    }

    /// `sentenceStart`, and how many characters the scan turned into an array (what a test pins, #2506).
    static func sentenceStartScan(atOrAfter offset: Int, before limit: Int, in text: String) -> (start: Int, charactersRead: Int) {
        guard offset > 0 else { return (0, 0) }
        let from = max(0, offset - windowLookBehind)
        guard let windowStart = text.index(text.startIndex, offsetBy: from, limitedBy: text.endIndex) else { return (offset, 0) }
        var charactersRead = 0
        // Past `reach` a start is the Margin's or later, and the answer is `offset`, so nothing there needs reading.
        let reach = max(limit, offset) - from + windowLookAhead
        var length = min(reach, windowGrowth)
        while true {
            let windowEnd = text.index(windowStart, offsetBy: length, limitedBy: text.endIndex)
            let characters = Array(text[windowStart..<(windowEnd ?? text.endIndex)])
            charactersRead += characters.count
            let isWholeStretch = windowEnd == nil || length >= reach
            // A stop near the end of a shorter window can't be judged yet: the word after it may be cut.
            let judged = isWholeStretch ? characters.count : characters.count - windowLookAhead
            var index = 0
            while index < characters.count {
                guard let start = nextSentenceStart(in: characters, at: &index), from + start >= offset else { continue }
                if start > judged { break }
                return (from + start < limit ? from + start : offset, charactersRead)
            }
            if isWholeStretch { return (offset, charactersRead) }
            length = min(reach, length * 4)
        }
    }

    /// Characters read before the offset, so the abbreviation and initial checks see the words around a stop.
    private static let windowLookBehind = 256
    /// Characters read past the Margin (or the end of the window) so the word after a stop is whole.
    private static let windowLookAhead = 128
    private static let windowGrowth = 2_048

    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "\u{00BB}"]
    /// Words whose full stop doesn't end a sentence, lower-cased with their inner stops.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "cf", "e.g", "i.e", "inc", "ltd"
    ]
    /// Abbreviations that are only abbreviations before a number (`Fig. 3`, `No. 5`; but "I said no. Then...").
    private static let numbered: Set<String> = ["fig", "no", "vol", "pp", "p", "ch", "sec", "art", "eq"]

    /// If a sentence break sits at `index`, the index where the next sentence starts. Moves `index` past what it
    /// looked at, so a run such as `?!` or `..."` is read once.
    static func nextSentenceStart(in characters: [Character], at index: inout Int) -> Int? {
        let here = index
        let character = characters[here]
        if character.isNewline {
            var end = here
            var breaks = 0
            while end < characters.count, characters[end].isWhitespace {
                if characters[end].isNewline { breaks += 1 }
                end += 1
            }
            index = max(end, here + 1)
            return breaks >= 2 && end < characters.count ? end : nil
        }
        guard terminators.contains(character) else {
            index += 1
            return nil
        }
        var end = here + 1
        while end < characters.count, terminators.contains(characters[end]) || closers.contains(characters[end]) { end += 1 }
        index = end
        // No gap after it: 3.5, a.m., or the end of the text.
        guard end < characters.count, characters[end].isWhitespace else { return nil }
        var start = end
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        guard start < characters.count else { return nil }
        let run = characters[here..<end]
        // A lower-case word after a full stop, an ellipsis or a closing quote carries the sentence on:
        // `Wait... then`, `"Why?" he asked`.
        // (A brand written like `iPhone` or `eBay` starts a sentence of its own after a full stop, but after an
        // ellipsis, which may be only a pause, it carries on: `Levels fell... mRNA counts rose`.)
        let pause = run.contains("\u{2026}") || run.filter { $0 == "." }.count > 1
        if run.contains(where: { $0 == "." || $0 == "\u{2026}" || closers.contains($0) }), characters[start].isLowercase,
           pause || !isCamelCaseWord(at: start, in: characters) {
            return nil
        }
        if characters[here] == ".", end == here + 1,
           isAbbreviation(before: here, in: characters, nextWordAt: start) { return nil }
        return start
    }

    /// Words that start a sentence far more often than they follow an initial or an abbreviation as a name does.
    /// "Vitamin A. Then" and "Main St. Then" end a sentence; "J. K. Rowling" and "St. Louis" don't.
    private static let sentenceOpeners: Set<String> = [
        "then", "the", "it", "he", "she", "they", "we", "you", "this", "that", "these", "those", "and", "but", "so",
        "there", "however", "now", "in", "on", "at", "as", "if", "when", "after", "before", "his", "her", "their",
        "our", "what", "who", "one", "some", "also", "next", "later"
    ]
    /// Abbreviations that are also common at the end of a sentence, so a sentence opener after them is a new sentence.
    private static let sometimesSentenceFinal: Set<String> = ["st", "mt", "sr", "jr", "inc", "ltd"]

    private static func word(at index: Int, in characters: [Character]) -> String {
        var end = index
        while end < characters.count, characters[end].isLetter || characters[end] == "'" || characters[end] == "\u{2019}" { end += 1 }
        return String(characters[index..<end])
    }

    private static func isCamelCaseWord(at index: Int, in characters: [Character]) -> Bool {
        let text = word(at: index, in: characters)
        return text.count > 1 && text.dropFirst().contains(where: \.isUppercase)
    }

    /// The word ending just before the full stop at `index`: a title, `e.g.`, `Fig.` before a number, an initialism
    /// such as `U.S.` or a single initial (`J. K. Rowling`). `nextWordAt` is where the next sentence would start.
    private static func isAbbreviation(before index: Int, in characters: [Character], nextWordAt start: Int) -> Bool {
        var begin = index
        while begin > 0, characters[begin - 1].isLetter || characters[begin - 1] == "." { begin -= 1 }
        let word = String(characters[begin..<index])
        let lowered = word.lowercased()
        let opensASentence = sentenceOpeners.contains(Self.word(at: start, in: characters).lowercased())
        if abbreviations.contains(lowered) { return !(sometimesSentenceFinal.contains(lowered) && opensASentence) }
        // `No. 5` and `Fig. 3`, but not "She said no. 5 people came": the word `no` must be written like an abbreviation.
        if characters[start].isNumber, numbered.contains(lowered) {
            return lowered != "no" || word.first?.isUppercase == true
        }
        // `U.S.`, `D.C.`: capitals separated by stops. "Lived in the U.S. Then" ends the sentence.
        let pieces = word.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count > 1, pieces.allSatisfy({ $0.count == 1 && $0.first?.isUppercase == true }) { return !opensASentence }
        // An initial follows a capitalised name or another initial, or starts the text. After a lower-case word a
        // single capital is a word ending the sentence ("so did I."), and "Vitamin A. Then" ends one too.
        guard word.count == 1, let only = word.first, only.isUppercase, only != "I", !opensASentence else { return false }
        var before = begin
        while before > 0, characters[before - 1] == " " { before -= 1 }
        guard before > 0, characters[before - 1].isLetter else { return true }
        var wordStart = before
        while wordStart > 0, characters[wordStart - 1].isLetter { wordStart -= 1 }
        return !characters[wordStart].isLowercase
    }
}

/// Which spoken Margins a "Play this moment" plays, and where each sits on the moment's clock (#1577).
public enum MarginMomentPlanner {
    public struct Anchors: Sendable, Equatable {
        public let target: MarginMomentAnchor
        public let others: [MarginMomentAnchor]
    }

    /// - Parameters:
    ///   - played: the Margin the listener chose.
    ///   - spoken: the item's spoken Margins, from every session (it may include `played`).
    ///   - targetMediaTimeMs: on a media clock, where the source stands once the chosen Margin's place is open. It
    ///     places the chosen Margin when it has only a text place (an article's prepared narration or its publisher's
    ///     recording found it, #1537). The item's other Margins need a media time of their own to play inline.
    ///   - text: the item's text. A narrated-text moment starts reading at a sentence start, so its other Margins
    ///     in the stretch before that start are left out (#1646). Empty means no snapping.
    /// - Returns: nil when the chosen Margin can't be placed on the clock.
    public static func anchors(
        played: Interjection,
        among spoken: [Interjection],
        clock: MarginMomentClock,
        targetMediaTimeMs: Int?,
        text: String = ""
    ) -> Anchors? {
        guard played.isSpokenItemMargin else { return nil }
        func place(_ margin: Interjection) -> Int? {
            if clock.isNarratedText { return clock.position(forTextOffset: margin.anchor.startChar) }
            return margin.anchor.mediaTimeMs
        }
        guard let targetMs = clock.isNarratedText ? place(played) : (played.anchor.mediaTimeMs ?? targetMediaTimeMs) else {
            return nil
        }
        let target = MarginMomentAnchor(marginId: identity(played), mediaTimeMs: targetMs)
        let readingStart = clock.isNarratedText ? clock.leadInStartOffset(forTargetPosition: targetMs, in: text) : 0
        let others = spoken
            .filter { $0.isSpokenItemMargin && identity($0) != target.marginId }
            .filter { !clock.isNarratedText || $0.anchor.startChar >= readingStart }
            .compactMap { margin in place(margin).map { MarginMomentAnchor(marginId: identity(margin), mediaTimeMs: $0) } }
        return Anchors(target: target, others: others)
    }

    /// A Margin's identity across sessions: the same id can appear in two sessions of one item. The app's
    /// `Gate1AppModel.marginIdentity` and `MarginRow.id` spell it the same way (`MarginCollectionTests` pins them).
    public static func identity(_ margin: Interjection) -> String {
        "\(margin.sessionId)::\(margin.id)"
    }
}
