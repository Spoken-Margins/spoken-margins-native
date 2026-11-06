#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Plays the sound that ends a spoken Margin without holding the main thread while the audio system answers.
///
/// Reading the audio session, building an `AVAudioPlayer` and starting it all wait on the system's audio service.
/// Everything here runs on one serial queue, so a `stop` sent after a `play` always lands after it, and a new cue
/// still replaces the one sounding. The caller gets the outcome on the main queue ("played" or "skipped:<why>")
/// for its diagnostics.
public final class OffMainOutcomeCuePlayer: @unchecked Sendable {
    /// Runs on the cue queue just before a cue would sound: nil to go ahead, or the reason to stay silent.
    public typealias SessionGate = @Sendable () -> String?

    private let queue = DispatchQueue(label: "spoken-margins.outcome-cue", qos: .userInitiated)
    private let sessionGate: SessionGate
    private var player: AVAudioPlayer?
    private var playingCue: MarginOutcomeCue?

    public init(sessionGate: @escaping SessionGate = { nil }) {
        self.sessionGate = sessionGate
    }

    /// Returns at once. `completion` runs on the main queue once the cue has started or been skipped.
    public func play(_ cue: MarginOutcomeCue, completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let result = playNow(cue)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Waits for the cue to start or be skipped, after every cue already sent. For callers that need the answer now.
    public func playAndWait(_ cue: MarginOutcomeCue) -> String {
        queue.sync { playNow(cue) }
    }

    /// Returns at once; the stop lands after every cue already sent.
    public func stop() {
        queue.async { [self] in stopNow() }
    }

    /// Blocks until everything sent so far has run (tests).
    public func drain() { queue.sync {} }

    /// Whether a cue is sounding right now (tests).
    public var isPlaying: Bool { queue.sync { player?.isPlaying == true } }

    private func playNow(_ cue: MarginOutcomeCue) -> String {
        // The watcher can report the same dead microphone again; a cue already sounding is not restarted.
        if cue.repeats, playingCue == cue, player?.isPlaying == true { return "played" }
        stopNow()
        if let reason = sessionGate() { return reason }
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

    private func stopNow() {
        player?.stop()
        player = nil
        playingCue = nil
    }
}
#endif
