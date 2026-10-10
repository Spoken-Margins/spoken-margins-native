import Foundation

/// How loud a spoken Margin should play, and which stretch of the source decides it (#467).
///
/// A Margin on a podcast whose file is on the device plays as loud as the episode around its
/// anchor. Every other Margin (a streamed episode, an article, a PDF) plays at the fixed podcast
/// level. `LoudnessLeveling` (#465) turns the target into a gain; this type only chooses the target.
public enum MarginLevelingTarget {
    /// Articles, PDFs and episodes that aren't on the device.
    public static let fixedLUFS = LoudnessLeveling.defaultTargetLUFS
    /// A source window quieter than this is a pause, an ad break or a music bed. It says nothing about
    /// how loud the show is, so the Margin plays at the fixed level instead of whispering along with it.
    public static let silentWindowLUFS = -40.0
    /// A match is kept inside these bounds, so a very quiet or very loud stretch can't pull a Margin
    /// somewhere uncomfortable. The listener's own volume still decides the rest.
    public static let quietestMatchLUFS = -30.0
    public static let loudestMatchLUFS = -12.0
    /// The stretch measured on each side of the Margin's anchor.
    public static let windowMsEachSide = 30_000
    /// A window shorter than this isn't enough audio to measure loudness reliably.
    public static let minimumWindowMs = 3_000
    /// Targets are rounded to this step, so Margins on nearly the same stretch share one cached copy.
    public static let cacheStepDB = 0.5

    public struct Window: Equatable, Sendable {
        public var startMs: Int
        public var durationMs: Int
    }

    /// The stretch of the source to measure around a Margin anchored at `anchorMediaTimeMs`, kept
    /// inside the episode when its length is known. Nil when too little of it is left to measure.
    public static func sourceWindow(anchorMediaTimeMs: Int, sourceDurationMs: Int?) -> Window? {
        let anchor = max(0, anchorMediaTimeMs)
        let start = max(0, anchor - windowMsEachSide)
        var end = anchor + windowMsEachSide
        if let sourceDurationMs { end = min(end, max(0, sourceDurationMs)) }
        guard end - start >= minimumWindowMs else { return nil }
        return Window(startMs: start, durationMs: end - start)
    }

    /// The loudness the Margin should be leveled to. Nil or unusable source measurements give the fixed
    /// level.
    public static func targetLUFS(sourceWindow measured: LoudnessMeasurement?) -> Double {
        guard let integrated = measured?.integratedLUFS, integrated.isFinite, integrated >= silentWindowLUFS else {
            return fixedLUFS
        }
        return min(loudestMatchLUFS, max(quietestMatchLUFS, rounded(integrated)))
    }

    /// `target` on the cache's grid.
    public static func rounded(_ target: Double) -> Double {
        (target / cacheStepDB).rounded() * cacheStepDB
    }
}
