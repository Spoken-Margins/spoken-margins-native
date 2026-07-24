import Foundation
import SessionKit

enum InterjectionPositionPresentation {
    static func percent(for interjection: Interjection, durationMs: Int?) -> Int? {
        guard let mediaTimeMs = interjection.anchor.mediaTimeMs else {
            return max(0, min(100, interjection.roughPercent))
        }
        guard let durationMs, durationMs > 0 else {
            return interjection.roughPercent > 0 ? max(0, min(100, interjection.roughPercent)) : nil
        }
        return max(0, min(100, Int((Double(max(0, mediaTimeMs)) / Double(durationMs)) * 100)))
    }

    static func timelineBadge(for interjection: Interjection, durationMs: Int?) -> String {
        if let percent = percent(for: interjection, durationMs: durationMs) {
            return "\(percent)%"
        }
        return mediaTime(interjection.anchor.mediaTimeMs ?? 0)
    }

    static func detailDescription(for interjection: Interjection, durationMs: Int?) -> String {
        guard let mediaTimeMs = interjection.anchor.mediaTimeMs else {
            return "Around \(percent(for: interjection, durationMs: durationMs) ?? 0)%"
        }
        let timestamp = mediaTime(mediaTimeMs)
        if let percent = percent(for: interjection, durationMs: durationMs) {
            return "\(timestamp) · around \(percent)%"
        }
        return timestamp
    }

    static func sortPercent(for interjection: Interjection, durationMs: Int?) -> Int {
        percent(for: interjection, durationMs: durationMs) ?? interjection.roughPercent
    }

    private static func mediaTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
