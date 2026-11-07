import AVFoundation
import SessionKit
import SessionKitAudio

/// Plays the sound that says how a spoken Margin ended (#1977), and says what it did.
@MainActor
protocol MarginOutcomeCuePlaying: AnyObject {
    /// "played", or "skipped:<why>". A repeating cue (`micStopped`) keeps playing until `stop()`.
    @discardableResult func play(_ cue: MarginOutcomeCue) -> String
    /// Starts the cue without waiting for the audio system; `completion` gets the `play` outcome on the main actor.
    func play(_ cue: MarginOutcomeCue, completion: @escaping @MainActor (String) -> Void)
    /// Sends the stop without waiting for it: the cue may still be sounding when this returns.
    func stop()
    /// Sends the stop; `finished` runs on the main actor once it has landed. For a next step that needs the cue gone.
    func stop(then finished: @escaping @MainActor () -> Void)
}

extension MarginOutcomeCuePlaying {
    func play(_ cue: MarginOutcomeCue, completion: @escaping @MainActor (String) -> Void) {
        completion(play(cue))
    }

    func stop(then finished: @escaping @MainActor () -> Void) {
        stop()
        finished()
    }
}

/// Like the ready cue, it never configures the audio session: it plays only when the session is already one that
/// plays sound and no other app's audio would be cut off, and otherwise the ending stays silent, as before. A new
/// cue replaces the one still playing. The session reads and the player's start run off the main thread, in order
/// (`OffMainOutcomeCuePlayer`).
@MainActor
final class MarginOutcomeCuePlayer: MarginOutcomeCuePlaying {
    /// Replaced by tests; the device's player otherwise.
    static var shared: MarginOutcomeCuePlaying = MarginOutcomeCuePlayer()

    private let core = OffMainOutcomeCuePlayer(sessionGate: {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord || session.category == .playback else { return "skipped:session_not_playing" }
        // Another app is playing over a session that doesn't mix: playing would take the session back and silence it.
        if session.isOtherAudioPlaying, !session.categoryOptions.contains(.mixWithOthers) { return "skipped:other_audio" }
        #endif
        return nil
    })

    /// Waits for the answer, as before: for a caller that records it at once.
    func play(_ cue: MarginOutcomeCue) -> String { core.playAndWait(cue) }

    func play(_ cue: MarginOutcomeCue, completion: @escaping @MainActor (String) -> Void) {
        core.play(cue) { result in Task { @MainActor in completion(result) } }
    }

    func stop() { core.stop() }

    func stop(then finished: @escaping @MainActor () -> Void) {
        core.stop { Task { @MainActor in finished() } }
    }
}
