import Foundation

/// Playback previews contain the listener's words. Failure details stay on the Margin.
public enum PlaybackMarginPreview {
    public static func text(displayText: String?, cleanedTranscript: String?, transcript: String?) -> String {
        for value in [displayText, cleanedTranscript, transcript] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Transcript pending"
    }
}
