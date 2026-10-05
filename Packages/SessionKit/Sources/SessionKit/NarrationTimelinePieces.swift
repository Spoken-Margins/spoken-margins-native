import Foundation

/// One stretch of an assembled narration's audio and the run of `Item.text` it reads.
public struct NarrationTimelinePiece: Equatable, Sendable {
    /// Spoken characters (in the projection's text) this piece says.
    public let spokenRange: Range<Int>
    public let startMs: Int
    public let endMs: Int
    /// Where the piece's words are in the source text.
    public let startChar: Int
    public let endChar: Int
}

/// Splits a rendered chunk's stretch of audio where its words jump over source text the
/// listener doesn't hear (#336, Codex audit on 2a0d49f).
///
/// A new-reader PDF is spoken without its references, so one chunk can say the last words of
/// the body and the first words of an appendix that sit thousands of characters apart in
/// `Item.text`. A single timeline segment for that chunk spans the references: halfway through
/// its audio, `PreparedNarrationFallback.textOffset` interpolates into them, and a Margin made
/// there opens on the whole span. Each piece here reads one unbroken run of the source, and its
/// share of the chunk's time is its share of the chunk's spoken characters.
public enum NarrationTimelinePieces {
    public static func pieces(
        spokenRange: Range<Int>,
        startMs: Int,
        endMs: Int,
        projection: NormalizedSpeechText,
        source: [Character]
    ) -> [NarrationTimelinePiece] {
        let offsets = projection.sourceOffsets
        let lower = max(0, min(spokenRange.lowerBound, offsets.count))
        let upper = max(lower, min(spokenRange.upperBound, offsets.count))
        let whole = piece(spokenRange, startMs, endMs, projection, source)
        guard upper - lower > 1, endMs - startMs > 1 else { return [whole] }

        var runs: [Range<Int>] = []
        var runStart = lower
        for index in (lower + 1)..<upper where skipsHeardWords(from: offsets[index - 1], to: offsets[index], in: source) {
            runs.append(runStart..<index)
            runStart = index
        }
        guard !runs.isEmpty else { return [whole] }
        runs.append(runStart..<upper)

        // Time follows spoken characters. A run too short to get its own millisecond joins the next.
        let total = Double(upper - lower)
        let duration = Double(endMs - startMs)
        var pieces: [NarrationTimelinePiece] = []
        var pieceStart = spokenRange.lowerBound
        var pieceStartMs = startMs
        for run in runs.dropLast() {
            let boundaryMs = startMs + Int((duration * Double(run.upperBound - lower) / total).rounded())
            guard boundaryMs > pieceStartMs, boundaryMs < endMs else { continue }
            pieces.append(piece(pieceStart..<run.upperBound, pieceStartMs, boundaryMs, projection, source))
            pieceStart = run.upperBound
            pieceStartMs = boundaryMs
        }
        pieces.append(piece(pieceStart..<spokenRange.upperBound, pieceStartMs, endMs, projection, source))
        return pieces
    }

    private static func piece(
        _ spoken: Range<Int>, _ startMs: Int, _ endMs: Int, _ projection: NormalizedSpeechText, _ source: [Character]
    ) -> NarrationTimelinePiece {
        NarrationTimelinePiece(
            spokenRange: spoken,
            startMs: startMs,
            endMs: endMs,
            startChar: projection.sourceOffset(atSpokenCharacterOffset: spoken.lowerBound),
            endChar: endChar(after: spoken.upperBound, projection: projection, source: source)
        )
    }

    /// The source offset a run ending before spoken character `spokenEnd` reaches. It runs up to
    /// the next spoken character, as a chunk's segment always did, unless that character is past
    /// skipped words: then it stops after the run's own last character.
    private static func endChar(after spokenEnd: Int, projection: NormalizedSpeechText, source: [Character]) -> Int {
        let next = projection.sourceOffset(atSpokenCharacterOffset: spokenEnd)
        let offsets = projection.sourceOffsets
        guard spokenEnd > 0, spokenEnd <= offsets.count else { return next }
        let last = offsets[spokenEnd - 1]
        return skipsHeardWords(from: last, to: next, in: source) ? last + 1 : next
    }

    /// True when the source between two consecutive spoken characters holds a letter or digit:
    /// words were left out, not just spacing or punctuation the normalizer dropped.
    private static func skipsHeardWords(from previous: Int, to next: Int, in source: [Character]) -> Bool {
        let start = max(0, previous + 1)
        let end = min(next, source.count)
        guard start < end else { return false }
        return source[start..<end].contains { $0.isLetter || $0.isNumber }
    }
}
