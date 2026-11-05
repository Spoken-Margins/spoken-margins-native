import Foundation

/// What a friend's Margin sounds like on this iPhone, decided in one place (#3365, #3412 audit). A shared Margin is a
/// recording or, when the sender typed it, a reading of their words by the iPhone's voice. Every way of playing one
/// (the card, the Now screen, the Timeline, Skim, the review of new Margins) asks `resolve` and plays what it says;
/// none reads `audioPath` itself. The first version of the written-Margin work taught the Timeline path about recordings
/// only, so a tap on a written Margin there failed. `SharedMarginAudioGuardTests` fails when a new path reads it directly.
public enum SharedMarginAudio: Equatable, Sendable {
    /// The sender's recording, found on this iPhone.
    case voiceFile(URL)
    /// A written Margin whose reading is on disk.
    case readingReady(WrittenMarginReading, file: URL)
    /// A written Margin whose reading is not yet rendered. `file` is where it will be; the caller starts the render.
    case readingRendering(WrittenMarginReading, file: URL)
    /// Nothing can play: a recording that is gone from this iPhone, or words the voice cannot read.
    case cannotBeRead

    /// Where a reading's file is and whether it is known to be on disk. `WrittenMarginReader` answers this from memory.
    public typealias ReadingState = (_ reading: WrittenMarginReading) -> (file: URL, isReady: Bool)

    public static func resolve(
        _ margin: ImportedCommentaryInterjection,
        in layer: ImportedCommentaryLayer,
        voiceFile: (_ audioPath: String) -> URL?,
        reading state: ReadingState
    ) -> SharedMarginAudio {
        if let path = margin.audioPath {
            // A Margin with a recording is never read aloud, even when the recording is gone (`isWritten` is false then).
            return voiceFile(path).map(SharedMarginAudio.voiceFile) ?? .cannotBeRead
        }
        guard let reading = WrittenMarginReading.of(margin, in: layer) else { return .cannotBeRead }
        let known = state(reading)
        return known.isReady ? .readingReady(reading, file: known.file) : .readingRendering(reading, file: known.file)
    }

    /// The file to hand a player, or nil when nothing can play. A reading still rendering gives the file it will have.
    public var file: URL? {
        switch self {
        case .voiceFile(let url), .readingReady(_, let url), .readingRendering(_, let url): url
        case .cannotBeRead: nil
        }
    }

    /// The reading, when this is a written Margin's.
    public var reading: WrittenMarginReading? {
        switch self {
        case .readingReady(let reading, _), .readingRendering(let reading, _): reading
        case .voiceFile, .cannotBeRead: nil
        }
    }

    /// Whether a Margin is worth offering to play at all: it has a recording, or words the voice can read. Answered from
    /// the Margin alone (no disk), so a screen can use it to enable a Play button. A recording that has gone missing
    /// still counts here; `resolve` is what finds that out when the listener taps.
    public static func canOffer(_ margin: ImportedCommentaryInterjection) -> Bool {
        margin.audioPath != nil || margin.isWritten
    }

    /// What the listener is told when `resolve` says `cannotBeRead`. The words follow what the Margin is: a recording
    /// that is gone never "can't be read aloud", and a note the voice can't read never "couldn't play".
    public static func unavailableWords(for margin: ImportedCommentaryInterjection) -> String {
        margin.audioPath != nil
            ? "That Margin's recording couldn't play."
            : "This Margin can't be read aloud on this iPhone."
    }
}
