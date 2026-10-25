import AVFoundation
import SessionKit

/// Plays the sound that says how a spoken Margin ended (#1977), and says what it did.
@MainActor
protocol MarginOutcomeCuePlaying: AnyObject {
    /// "played", or "skipped:<why>". A repeating cue (`micStopped`) keeps playing until `stop()`.
    @discardableResult func play(_ cue: MarginOutcomeCue) -> String
    func stop()
}

/// Like the ready cue, it never configures the audio session: it plays only when the session is already one that
/// plays sound, and otherwise the ending stays silent, as before. A new cue replaces the one still playing.
@MainActor
final class MarginOutcomeCuePlayer: MarginOutcomeCuePlaying {
    /// Replaced by tests; the device's player otherwise.
    static var shared: MarginOutcomeCuePlaying = MarginOutcomeCuePlayer()

    private var player: AVAudioPlayer?
    private var playingCue: MarginOutcomeCue?

    @discardableResult
    func play(_ cue: MarginOutcomeCue) -> String {
        // The watcher can report the same dead microphone again; a cue already sounding is not restarted.
        if cue.repeats, playingCue == cue, player?.isPlaying == true { return "played" }
        stop()
        #if os(iOS)
        let category = AVAudioSession.sharedInstance().category
        guard category == .playAndRecord || category == .playback else { return "skipped:session_not_playing" }
        #endif
        do {
            let player = try AVAudioPlayer(data: cue.wavData())
            player.volume = MarginOutcomeCue.volume
            player.numberOfLoops = cue.repeats ? -1 : 0
            self.player = player
            playingCue = cue
            return player.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingCue = nil
    }
}
