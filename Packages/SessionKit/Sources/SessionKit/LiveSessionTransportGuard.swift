import Foundation

/// Whether a play from outside the app is let through while a live session spoken Margin records on the phone (#3492).
///
/// On 2026-11-06 the owner recorded a spoken Margin in a live session with a podcast paused in the app's own player.
/// A Now Playing `play` arrived mid-recording; the player started, took the audio session, and iOS stopped the
/// recorder. A Lock Screen tap, a headphone click or the Watch can send that `play`. The owner's call (option 1 on
/// #3492): ignore it, so the Margin keeps recording. The listener ends the Margin with Stop and Save, which is the
/// only thing that should.
///
/// Only a command that starts playing is held back, and only from the remote surfaces (`now_playing…`,
/// `imported_margin_remote`). A tap on the app's own play button is deliberate and still goes through, and `pause`
/// and the skips never take the microphone. Pure, so it is host-tested; the app asks it before each command.
public enum LiveSessionTransportGuard {
    /// True when `command` from `origin` must be dropped because a live session spoken Margin is recording.
    public static func ignores(
        _ command: CompactControlCommand, origin: String, whileSpokenMarginRecords isRecording: Bool
    ) -> Bool {
        guard isRecording else { return false }
        switch command {
        case .play, .togglePlayPause: break
        default: return false
        }
        return remoteOriginPrefixes.contains { origin.hasPrefix($0) }
    }

    /// Where a command from the Lock Screen, headphones, the car or the Watch arrives from.
    static let remoteOriginPrefixes = ["now_playing", "imported_margin_remote"]
}
