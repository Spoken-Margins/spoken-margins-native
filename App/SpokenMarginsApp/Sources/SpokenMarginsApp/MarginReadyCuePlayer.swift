import AVFoundation
import SessionKit

/// Plays the ready cue (#1594) and says what it did.
@MainActor
protocol MarginReadyCuePlaying: AnyObject {
    /// "played", or "skipped:<why>" when the cue was not played.
    func playReadyCue() -> String
}

/// The cue never configures the audio session, so it cannot reroute the microphone (a Bluetooth headset
/// included) or interrupt the recorder: it plays only when the recording already has the session in
/// `.playAndRecord`, and otherwise the start stays silent, as before.
@MainActor
final class MarginReadyCuePlayer: MarginReadyCuePlaying {
    private var player: AVAudioPlayer?

    /// Where the cue is about to be heard, read from the session the recording already holds.
    static func currentRoute() -> ReadyCueOutputRoute {
        #if os(iOS)
        ReadyCueOutputRoute(outputPortTypes: AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue })
        #else
        .speaker
        #endif
    }

    func playReadyCue() -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playAndRecord else { return "skipped:session_not_recording" }
        #endif
        do {
            let player = try AVAudioPlayer(data: MarginReadyCue.wavData())
            player.volume = MarginReadyCue.volume(for: Self.currentRoute())
            self.player = player
            return player.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
        }
    }
}
