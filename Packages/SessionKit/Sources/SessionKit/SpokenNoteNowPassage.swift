import Foundation

/// A spoken note's own words on the Now tab (#4780).
///
/// Once a note has been played it has audio of its own, so Now used to give it the podcast layout ("Nearby Margins")
/// and its words showed only on the note's own screen. Here the note's sentences become the rows of #4453's whole-text
/// scene: one row per sentence as the note broke them (at pauses as well as stops, `SpokenNoteSentenceGrouping`), the
/// lit row taken from the playback clock and the note's own timeline (never the engine's text offset, which falls to 0
/// in a pause), and each Margin as a row after its sentence, placed by its segment id.
///
/// Pure values, built off the main actor once per note and timeline. The view only feeds them the clock.
public enum SpokenNoteNowPassage {
    /// One of the listener's Margins, drawn as a row right after the sentence it sits on.
    public struct MarginItem: Equatable, Sendable {
        /// The id of the sentence row it follows (`Words.Row.id`).
        public let afterRowId: Int
        public let marginId: String
        public let sessionId: String

        public init(afterRowId: Int, marginId: String, sessionId: String) {
            self.afterRowId = afterRowId
            self.marginId = marginId
            self.sessionId = sessionId
        }

        /// Unique among a note's Margins, and the end of the row's accessibility id.
        public var key: String { "\(sessionId)::\(marginId)" }
    }

    /// The note's text for Now and the rows made from it. The one place a note's Now text and rows are made.
    public struct Words: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            /// The id the scene draws for this sentence: its first non-space Character in `text`.
            public let id: Int
            public let ref: SpokenNote.SentenceRef
            /// Where the sentence starts on the joined audio; nil when it has no audio (no timeline, or no entry).
            public let startMs: Int?
            /// The sentence's start in `text` (its `sentenceStarts` value): the offset that lights this row.
            public let start: Int
        }

        /// The note's sentences joined as `SpokenNoteWholeTimeline` joins them, so its offsets are the timeline's.
        public let text: String
        /// Each row's sentence start in `text` (the range start the scene splits at), in order.
        public let sentenceStarts: [Int]
        public let rows: [Row]
        /// Whether the note has a timeline at all (it was joined for playback).
        public let hasTimeline: Bool
        /// The ids of the rows that have audio to play from: the rows a tap can seek to.
        public let rowIdsWithAudio: Set<Int>
        private let rowIndexByRef: [SpokenNote.SentenceRef: Int]
        private let rowIndexById: [Int: Int]
        /// The entries that have a row, as (start on the joined clock, row index), in timeline order.
        private let timed: [(startMs: Int, row: Int)]
        private let timedIsSorted: Bool
        private let timeline: SpokenNoteWholeTimeline?
        /// The joined recording's timeline, which Margins are placed on: their times are saved on the recording's clock
        /// whichever version plays (#4779), as the note's own screen reads them.
        private let marginTimeline: SpokenNoteWholeTimeline?

        /// The words on the clock of the file the open session plays (`playingMediaURL`; nil when the note isn't the
        /// open item): the Shorter pauses version's when it names that version, else the joined recording's (#4779).
        /// Now lights and seeks by these times. A version that no longer matches the takes gives rows with no times,
        /// never the recording's. Margins are placed on the recording's timeline either way. It reads files, so call it
        /// off the main actor.
        public init(note: SpokenNote, inFolder folder: URL, playingMediaURL: String?) {
            self.init(
                note: note,
                timeline: SpokenNoteWholePlayback.timeline(of: note, inFolder: folder, playingMediaURL: playingMediaURL),
                marginTimeline: SpokenNoteWholePlayback.timeline(of: note, inFolder: folder))
        }

        /// The words on `timeline`, with Margins placed on it too: the recording's timeline, or none.
        public init(note: SpokenNote, timeline: SpokenNoteWholeTimeline?) {
            self.init(note: note, timeline: timeline, marginTimeline: timeline)
        }

        private init(note: SpokenNote, timeline: SpokenNoteWholeTimeline?, marginTimeline: SpokenNoteWholeTimeline?) {
            var text = ""
            var starts: [Int] = []
            var rows: [Row] = []
            var byRef: [SpokenNote.SentenceRef: Int] = [:]
            var byId: [Int: Int] = [:]
            let entryStart = Dictionary(timeline?.entries.map { ($0.ref, $0.startMs) } ?? [], uniquingKeysWith: { first, _ in first })
            for ref in note.sentenceRefs {
                guard let sentence = note.sentence(ref) else { continue }
                // The same loop as `SpokenNoteWholeTimeline.init`: a space only when the text so far isn't empty.
                if !text.isEmpty { text.append(" ") }
                let start = text.count
                text.append(sentence.text)
                let leading = sentence.text.prefix(while: \.isWhitespace).count
                // A sentence with no words after trimming gives no row: there is nothing to show or light.
                guard leading < sentence.text.count else { continue }
                let id = start + leading
                byRef[ref] = rows.count
                byId[id] = rows.count
                starts.append(start)
                rows.append(Row(id: id, ref: ref, startMs: entryStart[ref], start: start))
            }
            var timed: [(startMs: Int, row: Int)] = []
            for entry in timeline?.entries ?? [] {
                guard let row = byRef[entry.ref] else { continue }
                timed.append((entry.startMs, row))
            }
            self.text = text
            self.sentenceStarts = starts
            self.rows = rows
            self.hasTimeline = timeline != nil
            self.rowIdsWithAudio = Set(rows.filter { $0.startMs != nil }.map(\.id))
            self.rowIndexByRef = byRef
            self.rowIndexById = byId
            self.timed = timed
            self.timedIsSorted = zip(timed, timed.dropFirst()).allSatisfy { $0.startMs <= $1.startMs }
            self.timeline = timeline
            self.marginTimeline = marginTimeline
        }

        public static func == (lhs: Words, rhs: Words) -> Bool {
            lhs.text == rhs.text && lhs.rows == rhs.rows && lhs.timeline == rhs.timeline
                && lhs.marginTimeline == rhs.marginTimeline
        }

        public func row(id: Int) -> Row? {
            rowIndexById[id].map { rows[$0] }
        }

        /// The offset to light for the media time `mediaTimeMs`: the start of the row whose timeline entry is the last
        /// one starting at or before it, so a pause keeps the sentence just heard lit. Nil with no time, no timed rows, or
        /// before the first one.
        public func sourceOffset(mediaTimeMs: Int?) -> Int? {
            guard let time = mediaTimeMs, !timed.isEmpty else { return nil }
            let found: Int?
            if timedIsSorted {
                // The first entry starting after `time`; the one before it is the answer.
                var lower = 0
                var upper = timed.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if timed[middle].startMs <= time { lower = middle + 1 } else { upper = middle }
                }
                found = lower > 0 ? timed[lower - 1].row : nil
            } else {
                found = timed.last(where: { $0.startMs <= time })?.row
            }
            return found.map { sentenceStarts[$0] }
        }

        /// The sentence starts after `fromOffset`, up to and including `toOffset`, in order: every row playback passed
        /// between two ticks, those with no audio included, so a short sentence between ticks is never read as a jump.
        /// With no `fromOffset`, or a move back or to the same place, just `[toOffset]`. Never empty.
        public func rowsCrossed(fromOffset: Int?, toOffset: Int) -> [Int] {
            guard let fromOffset, toOffset > fromOffset else { return [toOffset] }
            let crossed = sentenceStarts.filter { $0 > fromOffset && $0 <= toOffset }
            return crossed.isEmpty ? [toOffset] : crossed
        }

        /// Whether a move from the previous tick's media time to `toMs` is playback going on: forward by at most 4 s,
        /// which covers two ticks at up to 3× speed. A ±15 s skip, a longer scrub or any move back is a jump.
        public static func isContinuous(fromMs: Int?, toMs: Int) -> Bool {
            guard let fromMs else { return false }
            let step = toMs - fromMs
            return step >= 0 && step <= 4_000
        }

        /// The listener's active Margins on this note as rows, each after the sentence it sits on, found by its segment
        /// id (`SpokenNoteMargins.sentence(of:on:)`), never by its stored character range, which shifts when words arrive
        /// for an earlier take. Ordered by row, then as made. A Margin with no sentence, no saved place, or on anything but
        /// the note itself gets no row; with no recording timeline there are none. A time with no segment id is on the
        /// recording's clock, so it is looked up there even while the Shorter pauses version plays.
        public func marginItems(_ margins: [Interjection], itemId: String) -> [MarginItem] {
            guard let timeline = marginTimeline else { return [] }
            var placed: [(row: Int, margin: Interjection)] = []
            for margin in margins where margin.status == "active" && margin.targetType == .item && margin.hasPlace
                && margin.itemId == itemId {
                guard let ref = SpokenNoteMargins.sentence(of: margin.anchor, on: timeline), let row = rowIndexByRef[ref] else { continue }
                placed.append((row, margin))
            }
            placed.sort { lhs, rhs in
                if lhs.row != rhs.row { return lhs.row < rhs.row }
                return (lhs.margin.createdAt, lhs.margin.id) < (rhs.margin.createdAt, rhs.margin.id)
            }
            return placed.map { MarginItem(afterRowId: rows[$0.row].id, marginId: $0.margin.id, sessionId: $0.margin.sessionId) }
        }
    }

    /// Whether a note has words to show.
    public enum Availability: Equatable, Sendable {
        /// Only the loader's value before its first read.
        case loading
        case ready
        case partial(takesWithoutWords: Int)
        case noWords

        /// Nil (no file, or one that couldn't be read) and a note with no take that has words give `noWords`. A take has
        /// words when at least one of its sentences is not empty after trimming whitespace.
        public init(note: SpokenNote?) {
            guard let note, !note.takes.isEmpty else { self = .noWords; return }
            let without = note.takes.filter { take in
                !take.sentences.contains { !$0.text.allSatisfy(\.isWhitespace) }
            }.count
            if without == note.takes.count {
                self = .noWords
            } else if without == 0 {
                self = .ready
            } else {
                self = .partial(takesWithoutWords: without)
            }
        }
    }

    /// Which layout Now draws. It replaces the one flag the screen used to read (`isNativeAudio`).
    public enum NowLayout: Equatable, Sendable {
        /// "Nearby Margins": a podcast or other audio with no words to show.
        case audio
        /// The whole-text scene of an article or PDF (#4453).
        case text
        /// A spoken note's own words, in the same scene.
        case noteWords
        /// A spoken note with no words yet: the card, then "Nearby Margins".
        case noteNoWords
        /// A spoken note not read yet: neither the card nor the words.
        case noteLoading

        public static func choose(isNativeAudio: Bool, isSpokenNote: Bool, availability: Availability) -> NowLayout {
            if isSpokenNote {
                switch availability {
                case .ready, .partial: return .noteWords
                case .noWords: return .noteNoWords
                case .loading: return .noteLoading
                }
            }
            return isNativeAudio ? .audio : .text
        }
    }

    /// What a tap on one of a note's sentence rows does: the note screen's own conditions
    /// (`SpokenNoteRecordingView.isThisNoteOpen`).
    public enum RowTap: Equatable, Sendable {
        /// Plays from the sentence.
        case seeks
        /// Nothing.
        case inert
        /// Nothing, because the note has played to its end; the hint says to play it again.
        case inertFinished

        public static func rowTap(hasActiveSession: Bool, isSessionItem: Bool, targetIsSource: Bool, phase: SessionPhase,
                                  hasAudio: Bool) -> RowTap {
            if isSessionItem && phase == .finished { return .inertFinished }
            guard hasActiveSession, isSessionItem, targetIsSource, hasAudio else { return .inert }
            return .seeks
        }
    }
}
