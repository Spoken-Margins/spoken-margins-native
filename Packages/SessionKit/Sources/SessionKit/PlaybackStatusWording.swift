import Foundation

public enum PlaybackStatusWording {
    public static func humanReadableStatus(_ status: String) -> String {
        switch status {
        case "not_started":
            return "not started"
        case "rendering":
            return "preparing"
        case "starter_ready":
            return "starter ready"
        case "ready", "complete":
            return "ready"
        case "failed":
            return "failed"
        case "live_fallback":
            return "live fallback"
        case "queued":
            return "queued"
        case "downloading":
            return "downloading"
        case "transcribing":
            return "transcribing"
        case "unavailable":
            return "unavailable"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    public static func supportsOnDeviceSpeechGenerationStatus(targetType: String?) -> Bool {
        switch targetType {
        case TargetType.itemTextTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue:
            return true
        default:
            return false
        }
    }
}
