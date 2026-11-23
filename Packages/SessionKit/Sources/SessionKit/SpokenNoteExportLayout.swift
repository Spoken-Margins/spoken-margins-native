import Foundation

/// What the export reads of a spoken note besides its Library row (#4782): the note's own file and, when the note has
/// been joined for playback, its sentences on the joined clock. The app's engine reads it off the main thread.
public struct SpokenNoteExportInput: Equatable, Sendable {
    public let note: SpokenNote
    public let wholeTimeline: SpokenNoteWholeTimeline?

    public init(note: SpokenNote, wholeTimeline: SpokenNoteWholeTimeline?) {
        self.note = note
        self.wholeTimeline = wholeTimeline
    }

    /// Reads a note's file and joined timeline from its folder under `applicationSupport`, only ever reading (`peek()`
    /// leaves an unreadable file where it is). Nil when the item isn't a note, its id isn't safe, or its file is
    /// missing, unreadable or from a newer build: the export then uses the row's own words.
    /// The engine's `spokenNoteLoader` for notes under `applicationSupport` (nil when that folder couldn't be found:
    /// every note then exports from its row). Making it reads nothing; the engine calls it off the main thread.
    public static func loader(applicationSupport: URL?) -> @Sendable (Item) -> SpokenNoteExportInput? {
        { item in applicationSupport.flatMap { load(item: item, applicationSupport: $0) } }
    }

    public static func load(item: Item, applicationSupport: URL) -> SpokenNoteExportInput? {
        guard let store = SpokenNoteStarter.store(for: item, in: applicationSupport), let note = store.peek() else { return nil }
        return SpokenNoteExportInput(note: note, wholeTimeline: SpokenNoteWholePlayback.timeline(of: note, inFolder: store.folderURL))
    }
}

/// A spoken note laid out for an export (#4782): its recordings and sentences, the Margins placed after the sentence
/// they were made on, and the Margins that have no sentence. A pure value built from what was saved; nothing here
/// writes.
///
/// Placement is the note screen's rule (`SpokenNoteMargins.sentence(of:on:)`): the segment id first, then the last
/// sentence started at or before the media time. A Margin with no place saved (#4233) is never placed, and a Margin
/// from a session that read the note aloud before #3662 (a place, but no media time and no segment id) is placed by
/// where its anchor starts in the text.
public struct SpokenNoteExportLayout: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// Built from the note's own file.
        case note
        /// The note's file couldn't be read: built from the Library row's text and the stored timeline of the last
        /// playback.
        case lastPlayback = "last_playback"
    }

    public struct Sentence: Equatable, Sendable {
        /// The sentence's segment id on the note's timeline. Nil only for text the last playback's timeline doesn't
        /// cover (the fallback's tail, or a row with no timeline at all); a Margin is never placed on such text.
        public let segmentId: String?
        public let text: String
        /// Where the sentence starts in the note's text (`SpokenNote.text`, or the row's text in the fallback).
        public let startChar: Int?
        /// Where the sentence starts on the joined audio's clock, when it has audio there.
        public let startMs: Int?
        /// The Margins placed after this sentence, in the order they were made.
        public internal(set) var marginIds: [String]
    }

    public struct Recording: Equatable, Sendable {
        /// 1-based, in recording order.
        public let number: Int
        public let hasWords: Bool
        public internal(set) var sentences: [Sentence]
    }

    /// Where a placed Margin sits, and the words a Margin carries when the transcript is left out: its own sentence
    /// and the next one of the same recording, each at most `contextLimit` characters.
    public struct Placement: Equatable, Sendable {
        public let segmentId: String
        public let startChar: Int?
        public let startMs: Int?
        public let sentence: String
        public let nextSentence: String
    }

    public static let contextLimit = 500

    public let source: Source
    public internal(set) var recordings: [Recording]
    /// Every Margin placed on a sentence, by Margin id.
    public internal(set) var placements: [String: Placement]
    /// The note's Margins that sit on no sentence, in the order they were made.
    public internal(set) var unplacedMarginIds: [String]
    /// The note's Margins, sorted by when they were made (`createdAt`, then id).
    public let margins: [Interjection]

    /// The text the transcript is: `SpokenNote.text`, or the row's text in the fallback.
    public let text: String

    public var recordingCount: Int { recordings.count }
    public var recordingsWithWords: Int { recordings.filter(\.hasWords).count }
    /// Every one of at least one recording has words. Only meaningful for `.note`.
    public var isComplete: Bool { !recordings.isEmpty && recordings.allSatisfy(\.hasWords) }
    public var hasAnyWords: Bool { recordings.contains { $0.hasWords } }

    /// - Parameters:
    ///   - input: the note's file and joined timeline; nil when the note's file couldn't be read (the fallback).
    ///   - itemId: the note's Library item. Only active Margins on the item itself are laid out.
    ///   - itemText: the Library row's text, used only in the fallback.
    ///   - storedTimeline: the row's stored transcript timeline (the last playback's).
    public init(
        input: SpokenNoteExportInput?,
        itemId: String,
        itemText: String,
        storedTimeline: TranscriptTimeline?,
        margins: [Interjection]
    ) {
        let noteMargins = margins
            .filter { $0.itemId == itemId && $0.targetType == .item && $0.status == "active" }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        self.margins = noteMargins
        self.placements = [:]
        self.unplacedMarginIds = []
        if let input {
            source = .note
            text = input.note.text
            recordings = Self.recordings(of: input.note, wholeTimeline: input.wholeTimeline)
        } else {
            source = .lastPlayback
            text = itemText
            recordings = Self.fallbackRecordings(itemText: itemText, storedTimeline: storedTimeline)
        }
        let segmentLocation = Self.segmentLocations(recordings)
        for margin in noteMargins {
            guard margin.hasPlace,
                  let segmentId = Self.placedSegmentId(
                    margin.anchor, input: input, storedTimeline: storedTimeline,
                    recordings: recordings, segmentLocation: segmentLocation
                  ),
                  let (recordingIndex, sentenceIndex) = segmentLocation[segmentId] else {
                unplacedMarginIds.append(margin.id)
                continue
            }
            recordings[recordingIndex].sentences[sentenceIndex].marginIds.append(margin.id)
            let sentences = recordings[recordingIndex].sentences
            let sentence = sentences[sentenceIndex]
            let next = sentences.indices.contains(sentenceIndex + 1) ? sentences[sentenceIndex + 1].text : ""
            placements[margin.id] = Placement(
                segmentId: segmentId, startChar: sentence.startChar, startMs: sentence.startMs,
                sentence: String(sentence.text.prefix(Self.contextLimit)), nextSentence: String(next.prefix(Self.contextLimit))
            )
        }
    }

    // MARK: Building the recordings

    private static func recordings(of note: SpokenNote, wholeTimeline: SpokenNoteWholeTimeline?) -> [Recording] {
        var result: [Recording] = []
        var offset = 0
        var first = true
        for (takeIndex, take) in note.takes.enumerated() {
            var sentences: [Sentence] = []
            for (sentenceIndex, sentence) in take.sentences.enumerated() {
                if !first { offset += 1 } // the space `SpokenNote.text` puts between sentences
                first = false
                let ref = SpokenNote.SentenceRef(takeIndex: takeIndex, sentenceIndex: sentenceIndex)
                sentences.append(Sentence(
                    segmentId: SpokenNoteMargins.segmentId(takeId: take.id, sentenceIndex: sentenceIndex),
                    text: sentence.text, startChar: offset, startMs: wholeTimeline?.startMs(of: ref), marginIds: []
                ))
                offset += sentence.text.count
            }
            result.append(Recording(number: takeIndex + 1, hasWords: take.hasTranscript, sentences: sentences))
        }
        return result
    }

    private static func fallbackRecordings(itemText: String, storedTimeline: TranscriptTimeline?) -> [Recording] {
        let segments = storedTimeline?.segments ?? []
        var sentences = segments.map {
            Sentence(segmentId: $0.id, text: $0.text, startChar: $0.startChar, startMs: $0.startMs, marginIds: [])
        }
        if segments.isEmpty {
            // No timeline: the row's text is one block, and nothing can be placed on it.
            if !itemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences = [Sentence(segmentId: nil, text: itemText, startChar: 0, startMs: nil, marginIds: [])]
            }
        } else if let end = segments.compactMap(\.endChar).max(), end < itemText.count {
            // `attachPlayback` keeps a row's text that runs past its timeline (a transcript that arrived during the join).
            let tail = String(itemText.dropFirst(end)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                sentences.append(Sentence(segmentId: nil, text: tail, startChar: end, startMs: nil, marginIds: []))
            }
        }
        return [Recording(number: 1, hasWords: !sentences.isEmpty, sentences: sentences)]
    }

    private static func segmentLocations(_ recordings: [Recording]) -> [String: (Int, Int)] {
        var locations: [String: (Int, Int)] = [:]
        for (recordingIndex, recording) in recordings.enumerated() {
            for (sentenceIndex, sentence) in recording.sentences.enumerated() {
                if let id = sentence.segmentId, locations[id] == nil { locations[id] = (recordingIndex, sentenceIndex) }
            }
        }
        return locations
    }

    // MARK: Placing a Margin

    private static func placedSegmentId(
        _ anchor: Anchor,
        input: SpokenNoteExportInput?,
        storedTimeline: TranscriptTimeline?,
        recordings: [Recording],
        segmentLocation: [String: (Int, Int)]
    ) -> String? {
        if let input, let whole = input.wholeTimeline {
            // The note screen's own rule, on the joined clock.
            if let ref = SpokenNoteMargins.sentence(of: anchor, on: whole),
               ref.takeIndex < input.note.takes.count {
                return SpokenNoteMargins.segmentId(takeId: input.note.takes[ref.takeIndex].id, sentenceIndex: ref.sentenceIndex)
            }
        } else {
            // The note's file without its joined layout, or the fallback: the id first, then the stored timeline's time.
            if let id = anchor.transcriptSegmentId, segmentLocation[id] != nil { return id }
            if let timeMs = anchor.mediaTimeMs,
               let segment = storedTimeline?.segments.last(where: { $0.startMs <= timeMs }),
               segmentLocation[segment.id] != nil {
                return segment.id
            }
        }
        // A read-aloud Margin from before #3662: a place, but neither a media time nor a segment id.
        guard anchor.mediaTimeMs == nil, anchor.transcriptSegmentId == nil else { return nil }
        for recording in recordings {
            for sentence in recording.sentences {
                guard let id = sentence.segmentId, let start = sentence.startChar else { continue }
                if anchor.startChar >= start, anchor.startChar < start + sentence.text.count { return id }
            }
        }
        return nil
    }
}
