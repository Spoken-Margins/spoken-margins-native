import Foundation

/// Playing a spoken note start to finish (#3662, part of #3658).
///
/// A note is takes, each its own audio file. To play it the way every other item with its own audio plays (Now, the
/// Lock Screen, headphones, skip back, resume after a relaunch), the takes are laid end to end in one file, and the
/// note's Library item points at that file and at a transcript timeline whose times count from the start of the whole.
/// The shared playback engine does the rest; nothing here plays audio. The takes are only read, never changed, and the
/// joined file is a copy that can be rebuilt from them at any time.

/// How the joined file was made: which takes it was asked to hold, and where each one landed in it.
public struct SpokenNoteWholeAudioLayout: Codable, Equatable, Sendable {
    /// A take the join was asked to include. A later `prepare` compares these with the note's takes: any difference
    /// (a take added, a file gone) means the joined file is out of date.
    public struct Requested: Codable, Equatable, Sendable {
        public let id: String
        public let audioFileName: String
        public let durationMs: Int

        public init(id: String, audioFileName: String, durationMs: Int) {
            self.id = id
            self.audioFileName = audioFileName
            self.durationMs = durationMs
        }
    }

    /// A take that made it into the joined file, and where. A take the system could not read is not placed.
    public struct Placed: Codable, Equatable, Sendable {
        public let takeId: String
        public let startMs: Int
        public let durationMs: Int

        public init(takeId: String, startMs: Int, durationMs: Int) {
            self.takeId = takeId
            self.startMs = max(0, startMs)
            self.durationMs = max(0, durationMs)
        }
    }

    public static let currentVersion = 1

    public let version: Int
    public let requested: [Requested]
    public let placed: [Placed]
    public let durationMs: Int

    public init(requested: [Requested], placed: [Placed], durationMs: Int) {
        self.version = Self.currentVersion
        self.requested = requested
        self.placed = placed
        self.durationMs = max(0, durationMs)
    }
}

/// What a join laid down: for each source that went in, where it starts and how long it is, as the joined file
/// counts them (not as the recorder measured each take, which can differ by tens of milliseconds a take).
public struct SpokenNoteJoinMeasurement: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public let sourceIndex: Int
        public let startMs: Int
        public let durationMs: Int

        public init(sourceIndex: Int, startMs: Int, durationMs: Int) {
            self.sourceIndex = sourceIndex
            self.startMs = startMs
            self.durationMs = durationMs
        }
    }

    public let placements: [Placement]
    public let durationMs: Int

    public init(placements: [Placement], durationMs: Int) {
        self.placements = placements
        self.durationMs = durationMs
    }
}

/// A joiner that also says where each source landed. The system one is `SpokenNoteAudioJoiner` in SessionKitAudio.
public protocol SpokenNoteMeasuredAudioJoining: Sendable {
    /// Writes the sources that can be read, end to end, to `destination` (which does not exist yet). Throws when none
    /// can be read or the file can't be written.
    func joinMeasured(_ sources: [URL], to destination: URL) async throws -> SpokenNoteJoinMeasurement
}

/// Where a note's Library item gets its audio and transcript timeline. The database is one; a test is another.
public protocol SpokenNotePlaybackWriting: Sendable {
    /// Points the item at the joined audio and its timeline, and brings its text in step with the timeline's offsets.
    /// Returns false when there is no row to change (the note's row was never saved, or it is in the trash): nothing is
    /// written then, and a trashed row is not brought back.
    func attachPlayback(itemId: String, audioURL: URL, durationMs: Int, timeline: MediaTimeline, text: String) throws -> Bool
}

/// The note's sentences on the joined audio's clock.
public struct SpokenNoteWholeTimeline: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let ref: SpokenNote.SentenceRef
        public let segmentId: String
        public let startMs: Int
        public let endMs: Int
        public let startChar: Int
        public let endChar: Int
        public let text: String
    }

    /// The sentences that have audio, in note order. A sentence whose take is not in the joined file, or that starts after
    /// its take's audio ends, has no entry: its words show, and there is nothing to play behind it.
    public let entries: [Entry]
    public let durationMs: Int
    /// The note's text, exactly `SpokenNote.text`, which is what the item's text is and what the entries' offsets count in.
    public let text: String

    public init(note: SpokenNote, layout: SpokenNoteWholeAudioLayout) {
        var entries: [Entry] = []
        var fullText = ""
        for ref in note.sentenceRefs {
            guard let sentence = note.sentence(ref) else { continue }
            if !fullText.isEmpty { fullText.append(" ") }
            let startChar = fullText.count
            fullText.append(sentence.text)
            let endChar = fullText.count
            let take = note.takes[ref.takeIndex]
            guard let placed = layout.placed.first(where: { $0.takeId == take.id }),
                  sentence.startMs < placed.durationMs else { continue }
            let start = placed.startMs + sentence.startMs
            let end = placed.startMs + min(sentence.endMs, placed.durationMs)
            entries.append(Entry(
                ref: ref, segmentId: "note-\(take.id)-\(ref.sentenceIndex)",
                startMs: start, endMs: max(start + 1, end), startChar: startChar, endChar: endChar, text: sentence.text
            ))
        }
        self.entries = entries
        self.durationMs = layout.durationMs
        self.text = fullText
    }

    /// The timeline the shared player and the Now screen read.
    public var mediaTimeline: MediaTimeline {
        MediaTimeline(
            segments: entries.map {
                MediaTimelineSegment(id: $0.segmentId, startMs: $0.startMs, endMs: $0.endMs, startChar: $0.startChar, endChar: $0.endChar, text: $0.text)
            },
            chapters: [],
            durationMs: durationMs
        )
    }

    /// The sentence being spoken at `timeMs` on the joined clock: the last one that started at or before it, so the
    /// pause between two sentences, and the tail of a take, keep the sentence just heard lit. Nil before the first.
    public func ref(atMs timeMs: Int) -> SpokenNote.SentenceRef? {
        entries.last(where: { $0.startMs <= timeMs })?.ref
    }

    /// Where a sentence starts on the joined clock; nil when it has no audio.
    public func startMs(of ref: SpokenNote.SentenceRef) -> Int? {
        entries.first(where: { $0.ref == ref })?.startMs
    }
}

public enum SpokenNoteWholePlayback {
    /// The joined file and its layout sit in the note's own folder. Neither starts with `take-`, so launch recovery,
    /// which adopts `take-*.m4a` files that no take names, never mistakes the joined file for a lost recording.
    public static let audioFileName = "whole-note.m4a"
    public static let layoutFileName = "whole-note.json"

    public enum PrepareError: Error, Equatable, Sendable {
        /// `note.json` is missing, damaged or from a newer build. It is left exactly as it is.
        case noteUnreadable
        /// No take has audio on this phone that can be played.
        case noAudio
        /// The note has no saved Library row to play (or it is in the trash).
        case itemGone
    }

    /// What a Play needs to start the note.
    public struct Prepared: Equatable, Sendable {
        public let itemId: String
        public let audioURL: URL
        public let durationMs: Int
        public let timeline: SpokenNoteWholeTimeline
        /// The joined file was made again in this call (a take had been added, or it was missing).
        public let rebuilt: Bool
    }

    /// The joined file's place in a note's folder, whether or not it exists.
    public static func audioURL(inFolder folder: URL) -> URL { folder.appendingPathComponent(audioFileName) }

    /// The joined file when one is there. A cheap file-system check, safe wherever a start is decided; whether it holds
    /// every take is `prepare`'s question, asked by the Play control before it starts anything.
    public static func existingAudioURL(inFolder folder: URL) -> URL? {
        let url = audioURL(inFolder: folder)
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeRegular ? url : nil
    }

    /// The note's sentences on the joined file's clock, from the layout saved beside it. Nil when the note was never
    /// joined (or its layout can't be read). A take added since is simply not in it yet; the sentences of the takes that
    /// are keep their times, because a take is only ever added at the end.
    public static func timeline(of note: SpokenNote, inFolder folder: URL) -> SpokenNoteWholeTimeline? {
        guard existingAudioURL(inFolder: folder) != nil, let layout = readLayout(inFolder: folder) else { return nil }
        return SpokenNoteWholeTimeline(note: note, layout: layout)
    }

    /// Where the engine should play an item from: the note's joined file, when the item is a spoken note whose media was
    /// attached by `prepare`. Nil otherwise, so a start never falls back to reading the note's words aloud in a synthetic
    /// voice, which is not what a spoken note is. It names the file without looking for it, so it is safe on the main
    /// thread; a file that has gone is reported by the player, and `prepare` makes it again at the next Play.
    public static func playbackURL(for item: some LibraryItemFields, applicationSupport: URL) -> URL? {
        guard SpokenNoteItem.isSpokenNote(mediaType: item.mediaType), item.media?.url != nil,
              let noteId = SpokenNoteItem.noteId(fromReference: item.externalReference),
              let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else { return nil }
        return audioURL(inFolder: store.folderURL)
    }

    /// The takes a join should hold: each take whose audio file is on this phone as a plain file in the note's folder.
    public static func requestedTakes(of note: SpokenNote, inFolder folder: URL) -> [SpokenNoteWholeAudioLayout.Requested] {
        let fileManager = FileManager.default
        return note.takes.compactMap { take in
            guard SpokenNoteIntake.isPlainFileName(take.audioFileName),
                  take.audioFileName != audioFileName, take.audioFileName != layoutFileName else { return nil }
            // `attributesOfItem` does not follow a link, so only a regular file counts, as for every other reader.
            let type = (try? fileManager.attributesOfItem(atPath: folder.appendingPathComponent(take.audioFileName).path))?[.type]
            guard (type as? FileAttributeType) == .typeRegular else { return nil }
            return SpokenNoteWholeAudioLayout.Requested(id: take.id, audioFileName: take.audioFileName, durationMs: take.durationMs)
        }
    }

    /// Makes the note ready to play: joins the takes into the note's folder unless the file there already holds exactly
    /// these takes, then points the note's Library item at it. It only reads `note.json` and the takes' audio, and it
    /// writes the joined file, its layout and the item's media and timeline, nothing else.
    public static func prepare(
        store: SpokenNoteStore,
        joiner: any SpokenNoteMeasuredAudioJoining,
        writer: any SpokenNotePlaybackWriting
    ) async throws -> Prepared {
        guard let note = store.peek() else { throw PrepareError.noteUnreadable }
        let requested = requestedTakes(of: note, inFolder: store.folderURL)
        guard !requested.isEmpty else { throw PrepareError.noAudio }

        let audio = audioURL(inFolder: store.folderURL)
        let layout: SpokenNoteWholeAudioLayout
        var rebuilt = false
        if let stored = readLayout(inFolder: store.folderURL), stored.requested == requested,
           existingAudioURL(inFolder: store.folderURL) != nil {
            layout = stored
        } else {
            layout = try await rebuild(requested: requested, store: store, joiner: joiner)
            rebuilt = true
        }
        let timeline = SpokenNoteWholeTimeline(note: note, layout: layout)
        guard try writer.attachPlayback(
            itemId: SpokenNoteItem.itemId(forNoteId: note.id), audioURL: audio,
            durationMs: layout.durationMs, timeline: timeline.mediaTimeline, text: timeline.text
        ) else { throw PrepareError.itemGone }
        return Prepared(
            itemId: SpokenNoteItem.itemId(forNoteId: note.id), audioURL: audio,
            durationMs: layout.durationMs, timeline: timeline, rebuilt: rebuilt
        )
    }

    private static func readLayout(inFolder folder: URL) -> SpokenNoteWholeAudioLayout? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(layoutFileName)),
              let layout = try? JSONDecoder().decode(SpokenNoteWholeAudioLayout.self, from: data),
              layout.version <= SpokenNoteWholeAudioLayout.currentVersion else { return nil }
        return layout
    }

    private static func rebuild(
        requested: [SpokenNoteWholeAudioLayout.Requested],
        store: SpokenNoteStore,
        joiner: any SpokenNoteMeasuredAudioJoining
    ) async throws -> SpokenNoteWholeAudioLayout {
        let fileManager = FileManager.default
        let folder = store.folderURL
        // Written beside the real file and moved over it, so a player still reading the old one keeps reading it, and a
        // join that fails leaves the old file as it was.
        let temporary = folder.appendingPathComponent("whole-note.tmp-\(UUID().uuidString.lowercased()).m4a")
        do {
            let measurement = try await joiner.joinMeasured(requested.map { folder.appendingPathComponent($0.audioFileName) }, to: temporary)
            let placed = measurement.placements.compactMap { placement -> SpokenNoteWholeAudioLayout.Placed? in
                guard requested.indices.contains(placement.sourceIndex) else { return nil }
                return SpokenNoteWholeAudioLayout.Placed(
                    takeId: requested[placement.sourceIndex].id, startMs: placement.startMs, durationMs: placement.durationMs
                )
            }
            guard !placed.isEmpty, measurement.durationMs > 0 else { throw PrepareError.noAudio }
            let layout = SpokenNoteWholeAudioLayout(requested: requested, placed: placed, durationMs: measurement.durationMs)
            let target = audioURL(inFolder: folder)
            // `rename` replaces the file in one step, and a player that has the old one open keeps reading it.
            guard rename(temporary.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(layout).write(to: folder.appendingPathComponent(layoutFileName), options: .atomic)
            return layout
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
