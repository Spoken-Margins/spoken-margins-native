import Foundation

/// The timeline of a narration assembled from prepared chunks into one audio file (#336, #3777).
/// `SupertonicPreparedAudioAssembler.writePCM` appends each chunk's audio and asks this for the chunk's segments, and
/// the host tests build their files with the same type, so the segments a test reads are the ones the app writes.
///
/// The footnote session on a prepared file (`FootnoteMediaChimeDriver`) finds each note by its segment: an empty
/// character range and the chunk's own words. Before this type the tests copied the assembler's loop by hand, and the
/// copy had already drifted (a split chunk's pieces were named "piece" instead of their spoken words).
public struct AssembledNarrationTimeline: Sendable {
    public private(set) var segments: [MediaTimelineSegment] = []
    private let projection: NormalizedSpeechText
    private let source: [Character]
    private let spoken: [Character]

    /// - `projection`: the spoken text the chunks' offsets are in, mapped to `sourceText`
    ///   (`PreparedSpeechText.assemblyProjection(asides:)`).
    /// - `sourceText`: the text the segments' character ranges point into (`Item.text`).
    public init(projection: NormalizedSpeechText, sourceText: String) {
        self.projection = projection
        self.source = Array(sourceText)
        self.spoken = Array(projection.text)
    }

    /// Adds the segments of one chunk whose audio runs from `startMs` to `endMs` in the file, and returns their
    /// indexes. A chunk that speaks across skipped text (a PDF's references) gets a segment per stretch of the source
    /// it reads, so positions never land in what wasn't heard (#336). A chunk with no source characters (a footnote's
    /// aside) gets one segment with an empty range and the chunk's own words.
    @discardableResult
    public mutating func append(startOffset: Int, sourceLength: Int, text: String, startMs: Int, endMs: Int) -> Range<Int> {
        let first = segments.count
        let pieces = NarrationTimelinePieces.pieces(
            spokenRange: startOffset..<(startOffset + sourceLength),
            startMs: startMs, endMs: endMs, projection: projection, source: source
        )
        for piece in pieces {
            let lower = min(piece.spokenRange.lowerBound, spoken.count)
            let upper = min(max(lower, piece.spokenRange.upperBound), spoken.count)
            segments.append(MediaTimelineSegment(
                // Saved Margins point at these ids, so their form never changes.
                id: "supertonic-seg-\(String(format: "%04d", segments.count + 1))",
                startMs: piece.startMs,
                endMs: piece.endMs,
                startChar: piece.startChar,
                endChar: piece.endChar,
                text: pieces.count == 1 ? text : String(spoken[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return first..<segments.count
    }
}
