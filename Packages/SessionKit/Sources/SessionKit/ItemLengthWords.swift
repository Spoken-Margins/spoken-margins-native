import Foundation

/// The words for an item's total length, shared by the Library row's detail line and the item screen's length pill
/// (#4186), so the two cannot disagree. Pure and host-tested.
///
/// - Text: "about 12 min", an estimate at the listener's speed, so always "about".
/// - Recorded audio: "41 min" or "1 h 12 min", the file's own length at 1x, so never "about" and never scaled.
public enum ItemLengthWords {
    /// The length not yet started: `visible` for the screen, `spoken` for VoiceOver. Nil when there is nothing to say.
    /// Text (a character count) wins over a media length, as the Library row has always done; a caller that holds
    /// recorded audio passes no character count.
    public static func total(textCharacterCount: Int?, mediaDurationMs: Int?, playbackSpeed: Double) -> (visible: String, spoken: String)? {
        if let characters = textCharacterCount {
            guard let estimate = ListeningTimeEstimator.estimate(totalCharacters: characters, charactersHeard: 0, playbackSpeed: playbackSpeed)
            else { return nil }
            let spoken = estimate.totalSeconds < 60 ? "less than a minute" : "about \(spokenDuration(estimate.totalSeconds))"
            return (estimate.totalText, spoken)
        }
        guard let duration = mediaDurationMs, duration > 0 else { return nil }
        let seconds = Double(duration) / 1000
        guard seconds >= 60 else { return ("under 1 min", "less than a minute") }
        return (ListeningTimeEstimate.shortDuration(seconds), spokenDuration(seconds))
    }

    /// The item screen's length pill. Nil when the item shows none: a meeting transcript (its meeting line gives the
    /// length), or text with no character count.
    public static func pill(
        isNativeAudio: Bool,
        isMeetingTranscript: Bool,
        textCharacterCount: Int?,
        lengthMs: Int?,
        playbackSpeed: Double
    ) -> (visible: String, spoken: String)? {
        if isMeetingTranscript { return nil }
        if isNativeAudio {
            if let words = total(textCharacterCount: nil, mediaDurationMs: lengthMs, playbackSpeed: playbackSpeed) {
                return (words.visible, "Length, \(words.spoken)")
            }
            return ("Length unknown", "Length unknown. It shows once the episode downloads or plays.")
        }
        guard let words = total(textCharacterCount: textCharacterCount, mediaDurationMs: nil, playbackSpeed: playbackSpeed) else { return nil }
        return (words.visible, "Length, \(words.spoken)")
    }

    /// "5 minutes", "1 hour 5 minutes": the words `ListeningTimeEstimate.remainingSpokenText` uses.
    static func spokenDuration(_ seconds: Double) -> String {
        let (hours, minutes) = ListeningTimeEstimate.hoursAndMinutes(seconds)
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return parts.joined(separator: " ")
    }
}
