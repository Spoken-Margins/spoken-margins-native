import Foundation

/// Read-only labels for the playback source, independent of transport and timer ownership.
public enum PlaybackSourceLabels {
    public static func chapterTitle(_ chapter: String?, sourceTitle: String) -> String {
        for title in [chapter, sourceTitle] {
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Current source"
    }

    public static func sleepTag(state: SleepTimerState, remainingSeconds: Int?) -> String? {
        switch state {
        case .inactive: return nil
        case .expiryDeferred: return "Sleep after recording"
        case .armed(let mode, _, _):
            if mode == .endOfChapter { return "Sleep at chapter end" }
            guard let remainingSeconds else { return "Sleep timer on" }
            let seconds = max(0, remainingSeconds)
            let minutes = max(1, seconds / 60 + (seconds % 60 == 0 ? 0 : 1))
            return "Sleep \(minutes)m"
        }
    }

    public static func preparedAudio(fraction: Double?, isNativeAudio: Bool) -> String? {
        guard !isNativeAudio, let fraction, fraction.isFinite else { return nil }
        let percent = Int(max(0, min(1, fraction)) * 100)
        return "Prepared audio: \(percent)%"
    }
}
