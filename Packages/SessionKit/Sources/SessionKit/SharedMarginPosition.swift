import Foundation

public enum SharedMarginPosition {
    /// Raw rounded percentage; callers filter against the current position before clamping.
    public static func percent(mediaTimeMs: Int?, mediaDurationMs: Int?, charOffset: Int?, textLength: Int) -> Int? {
        let positionPercent: Int?
        if let mediaTimeMs = mediaTimeMs,
           let mediaDurationMs,
           mediaDurationMs > 0 {
            positionPercent = Int((Double(mediaTimeMs) / Double(mediaDurationMs) * 100).rounded())
        } else if let charOffset = charOffset,
                  textLength > 0 {
            positionPercent = Int((Double(charOffset) / Double(textLength) * 100).rounded())
        } else {
            positionPercent = nil
        }
        return positionPercent
    }
}
