import Foundation

/// Where to cut a spoken note for its version with shorter pauses (#4779), and how the two clocks line up.
///
/// A take is never written. These types only decide which stretches of each take's audio go into the note's
/// `clean/whole-note.m4a`, and map times between that file and the note's recording as made (`whole-note.m4a`).

/// One transcribed word of a take, with where it sits in the take's audio. Saved per take as `clean/words-<takeId>.json`.
public struct SpokenNoteTimedWord: Codable, Equatable, Sendable {
    public let text: String
    public let startMs: Int
    public let endMs: Int

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = max(0, startMs)
        self.endMs = max(self.startMs, endMs)
    }
}

/// What counts as a filler and how long pauses become. One rule for every note; `ruleVersion` names it in saved cut lists.
public enum SpokenNoteCleanPolicy {
    /// Bump when any rule below changes, so every saved cut list is made again.
    public static let ruleVersion = 1
    /// A quiet run this long or longer, holding no word, is shortened.
    public static let longPauseMs = 1_000
    /// What a shortened pause keeps: half at its start, half at its end.
    public static let keptPauseMs = 500
    /// The fade down and up at every join, in the render.
    public static let fadeMs = 10
    /// A kept piece shorter than this is too short to hear as anything but a click, so it goes with the cut around it.
    public static let shortestKeptMs = 20
    /// "you know" is cut only when a pause or punctuation sets it apart, as in the share cleanup.
    public static let isolatedPhraseBoundaryMs = 250

    private static let fillerPattern = try! NSRegularExpression(pattern: "^(u+m+|u+h+m*|e+r+m*|a+h+)$")

    /// The word with its leading and trailing punctuation removed, lowercased.
    static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// "um", "Um,", "UM", "umm", "uh.", "Uhm", "ah", "er", "erm". Never a hyphenated word ("uh-huh", "mm-hmm"), and
    /// never a real word that contains one ("her", "error").
    public static func isFiller(_ word: String) -> Bool {
        let token = bare(word)
        guard !token.isEmpty, !token.contains("-") else { return false }
        let range = NSRange(token.startIndex..., in: token)
        return fillerPattern.firstMatch(in: token, range: range) != nil
    }

    static func hasTrailingBoundaryPunctuation(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ",.;:!?—–".contains(last)
    }

    /// The spans to cut as fillers: every filler word, and every "you know" set apart by a pause or punctuation on both
    /// sides ("you know what" stays).
    public static func fillerSpans(in words: [SpokenNoteTimedWord]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        for word in words where isFiller(word.text) && word.endMs > word.startMs {
            spans.append(word.startMs..<word.endMs)
        }
        if words.count >= 2 {
            for index in 0..<(words.count - 1) where bare(words[index].text) == "you" && bare(words[index + 1].text) == "know" {
                let before = index == 0
                    || words[index].startMs - words[index - 1].endMs >= isolatedPhraseBoundaryMs
                    || hasTrailingBoundaryPunctuation(words[index - 1].text)
                let after = index + 1 == words.count - 1
                    || words[index + 2].startMs - words[index + 1].endMs >= isolatedPhraseBoundaryMs
                    || hasTrailingBoundaryPunctuation(words[index + 1].text)
                if before, after, words[index + 1].endMs > words[index].startMs {
                    spans.append(words[index].startMs..<words[index + 1].endMs)
                }
            }
        }
        return spans
    }
}

/// A take's kept stretches, in the take's own milliseconds. Saved per take as `clean/cut-<takeId>.json`.
public struct SpokenNoteTakeCut: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public init(startMs: Int, endMs: Int) {
            self.startMs = startMs
            self.endMs = endMs
        }
        public var lengthMs: Int { endMs - startMs }
    }

    public let ruleVersion: Int
    public let durationMs: Int
    /// In order, never overlapping, each at least `shortestKeptMs` long.
    public let kept: [Span]
    /// How many filler spans and shortened pauses the cut removed, for the caption and the record.
    public let fillersRemoved: Int
    public let pausesShortened: Int

    public init(ruleVersion: Int = SpokenNoteCleanPolicy.ruleVersion, durationMs: Int, kept: [Span], fillersRemoved: Int, pausesShortened: Int) {
        self.ruleVersion = ruleVersion
        self.durationMs = durationMs
        self.kept = kept
        self.fillersRemoved = fillersRemoved
        self.pausesShortened = pausesShortened
    }

    public var keptMs: Int { kept.reduce(0) { $0 + $1.lengthMs } }
    public var removedMs: Int { max(0, durationMs - keptMs) }
    /// True when nothing is cut: the whole take is one kept span.
    public var removesNothing: Bool { kept == [Span(startMs: 0, endMs: durationMs)] }

    /// The cut for one take.
    ///
    /// 1. Each filler's span counts as quiet.
    /// 2. Find the quiet runs (one flag per `windowMs`).
    /// 3. In each run of `longPauseMs` or more whose middle holds no other word, remove all but its first and last
    ///    `keptPauseMs / 2`.
    /// 4. Remove every filler span not already removed.
    /// 5. Kept is the take minus what was removed; a kept piece under `shortestKeptMs` goes with the cut around it.
    public static func make(words: [SpokenNoteTimedWord], silentFlags: [Bool], durationMs: Int, windowMs: Int = 20) -> SpokenNoteTakeCut {
        guard durationMs > 0 else {
            return SpokenNoteTakeCut(durationMs: 0, kept: [], fillersRemoved: 0, pausesShortened: 0)
        }
        let fillers = SpokenNoteCleanPolicy.fillerSpans(in: words).map { max(0, $0.lowerBound)..<min(durationMs, $0.upperBound) }
            .filter { !$0.isEmpty }
        let realWords = words.filter { !SpokenNoteCleanPolicy.isFiller($0.text) && $0.endMs > $0.startMs }
            .map { $0.startMs..<$0.endMs }
            .filter { word in !fillers.contains { $0.contains(word.lowerBound) && word.upperBound <= $0.upperBound } }

        var quiet = silentFlags
        for span in fillers {
            let first = max(0, span.lowerBound / windowMs)
            let last = min(quiet.count - 1, max(first, (span.upperBound - 1) / windowMs))
            if first <= last { for index in first...last { quiet[index] = true } }
        }

        var removed: [Range<Int>] = []
        var pauses = 0
        let edge = SpokenNoteCleanPolicy.keptPauseMs / 2
        var runStart: Int?
        for index in 0...quiet.count {
            let isQuiet = index < quiet.count && quiet[index]
            if isQuiet, runStart == nil {
                runStart = index * windowMs
            } else if !isQuiet, let start = runStart {
                runStart = nil
                let end = min(durationMs, index * windowMs)
                guard end - start >= SpokenNoteCleanPolicy.longPauseMs else { continue }
                let middle = (start + edge)..<(end - edge)
                guard !middle.isEmpty, !realWords.contains(where: { $0.overlaps(middle) }) else { continue }
                removed.append(middle)
                pauses += 1
            }
        }
        for span in fillers where !removed.contains(where: { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }) {
            removed.append(span)
        }

        let merged = mergeRanges(removed)
        var kept: [Span] = []
        var cursor = 0
        for range in merged {
            if range.lowerBound > cursor { kept.append(Span(startMs: cursor, endMs: range.lowerBound)) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < durationMs { kept.append(Span(startMs: cursor, endMs: durationMs)) }
        kept.removeAll { $0.lengthMs < SpokenNoteCleanPolicy.shortestKeptMs }
        return SpokenNoteTakeCut(durationMs: durationMs, kept: kept, fillersRemoved: fillers.count, pausesShortened: pauses)
    }

    static func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Where each kept stretch landed in `clean/whole-note.m4a`, as measured from the render.
public struct SpokenNoteCleanPlacement: Codable, Equatable, Sendable {
    public let takeId: String
    public let takeStartMs: Int
    public let takeEndMs: Int
    public let outputStartMs: Int

    public init(takeId: String, takeStartMs: Int, takeEndMs: Int, outputStartMs: Int) {
        self.takeId = takeId
        self.takeStartMs = takeStartMs
        self.takeEndMs = max(takeStartMs, takeEndMs)
        self.outputStartMs = outputStartMs
    }

    public var lengthMs: Int { takeEndMs - takeStartMs }
}

/// The two clocks of a note: "recorded" is the joined recording as made (`whole-note.m4a`), "clean" is the version
/// with shorter pauses. Both lookups are binary searches over the kept stretches.
public struct SpokenNoteCleanMap: Equatable, Sendable {
    struct Piece: Equatable, Sendable {
        let recordedStartMs: Int
        let recordedEndMs: Int
        let cleanStartMs: Int
    }

    let pieces: [Piece]
    public let cleanDurationMs: Int
    public let recordedDurationMs: Int

    /// `recorded` places each take on the recording's clock; a placement whose take isn't in it is skipped.
    public init(placements: [SpokenNoteCleanPlacement], recorded: SpokenNoteWholeAudioLayout, cleanDurationMs: Int) {
        var pieces: [Piece] = []
        for placement in placements {
            guard let take = recorded.placed.first(where: { $0.takeId == placement.takeId }) else { continue }
            let start = take.startMs + min(placement.takeStartMs, take.durationMs)
            let end = take.startMs + min(placement.takeEndMs, take.durationMs)
            guard end > start else { continue }
            pieces.append(Piece(recordedStartMs: start, recordedEndMs: end, cleanStartMs: placement.outputStartMs))
        }
        self.pieces = pieces.sorted { $0.recordedStartMs < $1.recordedStartMs }
        self.cleanDurationMs = max(0, cleanDurationMs)
        self.recordedDurationMs = recorded.durationMs
    }

    public var pieceCount: Int { pieces.count }

    /// A recorded time inside a cut maps to the start of the next kept stretch (the end of the file after the last).
    public func cleanMs(fromRecordedMs recordedMs: Int) -> Int {
        cleanMsCounting(fromRecordedMs: recordedMs).ms
    }

    public func recordedMs(fromCleanMs cleanMs: Int) -> Int {
        recordedMsCounting(fromCleanMs: cleanMs).ms
    }

    func cleanMsCounting(fromRecordedMs recordedMs: Int) -> (ms: Int, comparisons: Int) {
        let (index, comparisons) = Self.lastIndex(in: pieces, atOrBefore: recordedMs, key: \.recordedStartMs)
        guard let index else { return (pieces.first?.cleanStartMs ?? 0, comparisons) }
        let piece = pieces[index]
        if recordedMs < piece.recordedEndMs { return (piece.cleanStartMs + (recordedMs - piece.recordedStartMs), comparisons + 1) }
        let next = index + 1 < pieces.count ? pieces[index + 1].cleanStartMs : cleanDurationMs
        return (next, comparisons + 1)
    }

    func recordedMsCounting(fromCleanMs cleanMs: Int) -> (ms: Int, comparisons: Int) {
        let (index, comparisons) = Self.lastIndex(in: pieces, atOrBefore: cleanMs, key: \.cleanStartMs)
        guard let index else { return (pieces.first?.recordedStartMs ?? 0, comparisons) }
        let piece = pieces[index]
        let length = piece.recordedEndMs - piece.recordedStartMs
        return (piece.recordedStartMs + min(cleanMs - piece.cleanStartMs, length), comparisons)
    }

    /// The last piece whose key is at or before `value`, by binary search, and how many comparisons it took.
    static func lastIndex(in pieces: [Piece], atOrBefore value: Int, key: KeyPath<Piece, Int>) -> (Int?, Int) {
        var low = 0
        var high = pieces.count
        var comparisons = 0
        while low < high {
            let mid = (low + high) / 2
            comparisons += 1
            if pieces[mid][keyPath: key] <= value { low = mid + 1 } else { high = mid }
        }
        return (low == 0 ? nil : low - 1, comparisons)
    }
}

extension SpokenNoteWholeTimeline {
    /// The note's sentences on the clock of the version with shorter pauses. Same segment ids as the recording's timeline; a
    /// sentence cut away entirely ("Um.") starts at the next kept moment and lasts 1 ms.
    public init(note: SpokenNote, layout: SpokenNoteWholeAudioLayout, map: SpokenNoteCleanMap) {
        let recorded = SpokenNoteWholeTimeline(note: note, layout: layout)
        self.init(
            entries: recorded.entries.map { entry in
                let start = map.cleanMs(fromRecordedMs: entry.startMs)
                let end = map.cleanMs(fromRecordedMs: entry.endMs)
                return Entry(
                    ref: entry.ref, segmentId: entry.segmentId, startMs: start, endMs: max(start + 1, end),
                    startChar: entry.startChar, endChar: entry.endChar, text: entry.text
                )
            },
            durationMs: map.cleanDurationMs,
            text: recorded.text
        )
    }
}
