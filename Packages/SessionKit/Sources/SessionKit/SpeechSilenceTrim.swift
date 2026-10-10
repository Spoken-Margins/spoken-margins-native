import Foundation

/// The silence Supertonic leaves around every rendered chunk, and how much of it the player keeps (#586).
///
/// Measured on the Mac with voice M2 at 0.88×, over the first pages of an arXiv paper (158 chunks,
/// `research/C2/chunk_gap.py`): the model puts a median 0.59 s of silence before the speech and
/// 0.71 s after it (up to 2.0 s), in every chunk, and the player adds
/// `RenderedSpeechChunkBoundary.transitionDelay` on top. Between two chunks that is a gap of
/// 1.4 s (median; 0.6–2.8 s). Between two sentences inside one chunk the same model pauses about
/// 0.5 s, and between clauses 0.3–0.45 s. A listener hears the chunk seams as stalls, worst after
/// a comma, where the chunker has to cut a long sentence.
///
/// Rendered chunks are trimmed to their speech plus a short pad on each side, so a seam sounds like
/// the model's own pause. The chunk plan is untouched, so audio prepared earlier stays valid.
public enum SpeechSilenceTrim {
    /// Loudness is the RMS over windows this long.
    public static let windowSeconds = 0.010
    /// A window whose RMS is above this holds speech (about -40 dBFS). The model's silence is far below it.
    public static let silenceFloor: Float = 0.01
    /// Silence kept before the first speech and after the last, so a chunk neither clips its first
    /// consonant nor lands hard on the next one.
    public static let leadingPadSeconds = 0.05
    public static let trailingPadSeconds = 0.12

    /// The samples of `samples` to keep: the speech with its pads. Nil when no window holds speech.
    public static func speechRange(in samples: [Float], sampleRate: Int) -> Range<Int>? {
        let window = Int((Double(sampleRate) * windowSeconds).rounded())
        guard sampleRate > 0, window > 0, samples.count >= window else { return nil }
        let windowCount = samples.count / window
        let floorEnergy = Double(silenceFloor) * Double(silenceFloor) * Double(window)

        func hasSpeech(_ index: Int) -> Bool {
            var energy = 0.0
            for position in (index * window)..<((index + 1) * window) {
                energy += Double(samples[position]) * Double(samples[position])
            }
            return energy > floorEnergy
        }

        guard let first = (0..<windowCount).first(where: hasSpeech),
              let last = (0..<windowCount).reversed().first(where: hasSpeech) else { return nil }
        let leadingPad = Int((Double(sampleRate) * leadingPadSeconds).rounded())
        let trailingPad = Int((Double(sampleRate) * trailingPadSeconds).rounded())
        let start = max(0, first * window - leadingPad)
        let end = min(samples.count, (last + 1) * window + trailingPad)
        return start..<end
    }
}
