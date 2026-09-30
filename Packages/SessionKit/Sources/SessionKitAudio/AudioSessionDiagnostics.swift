#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// The shared audio session's state as privacy-safe diagnostic fields. On the owner's phone,
/// Supertonic went silent while the app reported "playing" and only a route change restored sound
/// (#288); these fields let a stall or heartbeat record what the session looked like then.
public enum AudioSessionDiagnostics {
    public static func fields() -> [String: String] {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return [
            "sessionCategory": session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
            "sessionMode": session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
            "sessionOptions": String(session.categoryOptions.rawValue),
            "route": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+"),
            "otherAudioPlaying": String(session.isOtherAudioPlaying),
            "silencedHint": String(session.secondaryAudioShouldBeSilencedHint),
            "outputVolume": String(format: "%.2f", session.outputVolume)
        ]
        #else
        return [:]
        #endif
    }

    /// A player's own state: rate, whether it believes it is playing, and why it is waiting.
    public static func fields(for player: AVPlayer?) -> [String: String] {
        guard let player else { return ["player": "none"] }
        let status: String
        switch player.timeControlStatus {
        case .playing: status = "playing"
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        @unknown default: status = "unknown"
        }
        let seconds = player.currentTime().seconds
        return [
            "playerRate": String(format: "%.2f", player.rate),
            "playerStatus": status,
            "playerWaitReason": player.reasonForWaitingToPlay?.rawValue ?? "none",
            "playerItemStatus": String(player.currentItem?.status.rawValue ?? -1),
            "playerTimeMs": seconds.isFinite ? String(Int(seconds * 1_000)) : "-1"
        ]
    }
}
#endif
