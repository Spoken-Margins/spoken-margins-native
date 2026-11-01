import Foundation

/// One sentence of a take's transcript, with where it sits in that take's audio (#1609, slice 1 of the spoken note).
public struct SpokenNoteSentence: Codable, Equatable, Sendable {
    public let text: String
    /// Milliseconds from the start of the take's audio. Never negative.
    public let startMs: Int
    /// Never before `startMs`.
    public let endMs: Int

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = max(0, startMs)
        self.endMs = max(self.startMs, endMs)
    }
}

/// One stretch of dictation: an audio file and, once the transcriber has run, its sentences. A take is never edited
/// after it is added; the only change a note allows is filling in a transcript that hadn't arrived yet.
public struct SpokenNoteTake: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// Relative to the note's folder, so a note moves with its folder.
    public let audioFileName: String
    public let durationMs: Int
    public let createdAt: Date
    public let sentences: [SpokenNoteSentence]

    public init(id: String, audioFileName: String, durationMs: Int, createdAt: Date, sentences: [SpokenNoteSentence] = []) {
        self.id = id
        self.audioFileName = audioFileName
        self.durationMs = max(0, durationMs)
        self.createdAt = createdAt
        self.sentences = sentences
    }

    public var hasTranscript: Bool { !sentences.isEmpty }
}

/// Where to play for a sentence: which take's audio, and the span of it.
public struct SpokenNotePlayback: Equatable, Sendable {
    public let takeId: String
    public let audioFileName: String
    public let startMs: Int
    public let endMs: Int
}

/// A spoken note: the listener's dictation as an ordered list of takes (#1609).
///
/// A pure value. Appending a take never changes an earlier one, and no operation here removes text: a note's text
/// is every take's sentences in order, as they were dictated. Tapping a sentence maps to a span of audio, and a
/// position in the audio maps back to a sentence. Slices 2 to 5 (record over, Clean view, Margins, sharing) build on
/// this and are in the issue.
public struct SpokenNote: Codable, Equatable, Sendable {
    /// Bump when the stored shape changes in a way an older build can't read.
    public static let currentSchemaVersion = 1

    /// A sentence's place in the whole note: which take, and which sentence of it.
    public struct SentenceRef: Equatable, Sendable {
        public let takeIndex: Int
        public let sentenceIndex: Int
    }

    public let id: String
    public let schemaVersion: Int
    public private(set) var takes: [SpokenNoteTake]

    public init(id: String, takes: [SpokenNoteTake] = []) {
        self.id = id
        self.schemaVersion = SpokenNote.currentSchemaVersion
        var seen = Set<String>()
        self.takes = takes.filter { seen.insert($0.id).inserted }
    }

    public var isEmpty: Bool { takes.isEmpty }

    /// Adds a take at the end. A take whose id is already in the note is refused, so a save that runs twice can't
    /// double a take. Returns whether it was added.
    @discardableResult
    public mutating func appendTake(_ take: SpokenNoteTake) -> Bool {
        guard !takes.contains(where: { $0.id == take.id }) else { return false }
        takes.append(take)
        return true
    }

    /// Fills in the transcript of a take that has none yet (the transcriber finishes after the audio is saved). A
    /// take that already has a transcript keeps it: dictated text is never replaced. Returns whether it was set.
    @discardableResult
    public mutating func setTranscript(_ sentences: [SpokenNoteSentence], forTake takeId: String) -> Bool {
        guard let index = takes.firstIndex(where: { $0.id == takeId }), !takes[index].hasTranscript, !sentences.isEmpty else {
            return false
        }
        let take = takes[index]
        takes[index] = SpokenNoteTake(
            id: take.id, audioFileName: take.audioFileName, durationMs: take.durationMs,
            createdAt: take.createdAt, sentences: sentences
        )
        return true
    }

    /// Every sentence of the note, in order.
    public var sentenceRefs: [SentenceRef] {
        takes.enumerated().flatMap { takeIndex, take in
            take.sentences.indices.map { SentenceRef(takeIndex: takeIndex, sentenceIndex: $0) }
        }
    }

    public func sentence(_ ref: SentenceRef) -> SpokenNoteSentence? {
        guard takes.indices.contains(ref.takeIndex), takes[ref.takeIndex].sentences.indices.contains(ref.sentenceIndex) else {
            return nil
        }
        return takes[ref.takeIndex].sentences[ref.sentenceIndex]
    }

    /// The note's text: every sentence in order, one space between. Never trimmed or reflowed beyond that.
    public var text: String {
        takes.flatMap(\.sentences).map(\.text).joined(separator: " ")
    }

    /// The audio span to play for a sentence, clamped to its take's audio. Nil when the sentence is unknown or lies
    /// wholly past the end of the audio (its text still shows; there is nothing to play behind it).
    public func playback(for ref: SentenceRef) -> SpokenNotePlayback? {
        guard let sentence = sentence(ref) else { return nil }
        let take = takes[ref.takeIndex]
        guard sentence.startMs < take.durationMs else { return nil }
        return SpokenNotePlayback(
            takeId: take.id, audioFileName: take.audioFileName,
            startMs: sentence.startMs, endMs: min(sentence.endMs, take.durationMs)
        )
    }

    /// The sentence being spoken at `timeMs` in a take's audio: the last sentence that started at or before it.
    /// Sentences that overlap resolve to the later one; a time before the first sentence, a take without a
    /// transcript and an unknown take give nil.
    public func sentence(inTake takeId: String, atMs timeMs: Int) -> SentenceRef? {
        guard let takeIndex = takes.firstIndex(where: { $0.id == takeId }), timeMs >= 0 else { return nil }
        let sentences = takes[takeIndex].sentences
        guard let index = sentences.indices.last(where: { sentences[$0].startMs <= timeMs }) else { return nil }
        return SentenceRef(takeIndex: takeIndex, sentenceIndex: index)
    }
}

/// A note's file. A missing file is an empty note. A file that is there but can't be read (damaged, or written by a
/// newer build) is set aside under another name, never overwritten, so the next save can't destroy dictation that a
/// later build might read.
public struct SpokenNoteStore: Sendable {
    public let folderURL: URL
    public let noteId: String

    public init(folderURL: URL, noteId: String) {
        self.folderURL = folderURL
        self.noteId = noteId
    }

    public var fileURL: URL { folderURL.appendingPathComponent("note.json") }
    public var setAsideURL: URL { folderURL.appendingPathComponent("note.unreadable.json") }

    public func load() -> SpokenNote {
        guard let data = try? Data(contentsOf: fileURL) else { return SpokenNote(id: noteId) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let note = try? decoder.decode(SpokenNote.self, from: data), note.schemaVersion <= SpokenNote.currentSchemaVersion {
            return SpokenNote(id: note.id, takes: note.takes)
        }
        setAside()
        return SpokenNote(id: noteId)
    }

    public func save(_ note: SpokenNote) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(note).write(to: fileURL, options: .atomic)
    }

    private func setAside() {
        // The first free name, so an unreadable file set aside earlier is never overwritten.
        let fileManager = FileManager.default
        var target = setAsideURL
        var number = 1
        while fileManager.fileExists(atPath: target.path) {
            number += 1
            target = folderURL.appendingPathComponent("note.unreadable.\(number).json")
        }
        try? fileManager.moveItem(at: fileURL, to: target)
    }
}
