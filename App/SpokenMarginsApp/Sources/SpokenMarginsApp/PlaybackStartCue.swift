import AVFoundation
import Combine
import SessionKit

/// Watches playback starts for #357. Silence while a voice warms up reads as failure when listening eyes-free, so
/// a start that is still silent after 0.8 s gets a short soft chime. Each start's time to first audio goes into
/// diagnostics as `firstAudioMs:<item id>`.
///
/// The chime never configures the audio session: it plays only when the start has already put the session in its
/// `.playback` category, and otherwise the start stays silent, as before.
@MainActor
final class PlaybackStartCue: ObservableObject {
    private var watch = PlaybackStartWatch()
    private var cueTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let now: () -> Date
    /// Tests replace the chime; it returns what the cue did.
    private let playChime: (@MainActor () -> String)?
    /// Writes one diagnostic (key, value), normally into the model's diagnostics.
    private let record: @MainActor (String, String) -> Void

    private var subscription: AnyCancellable?

    /// `snapshots` is the model's `$snapshot`. Subscribing here rather than from a view keeps the cue working when
    /// playback starts with no window attached (a Live Activity or an intent after a background launch).
    init(
        snapshots: AnyPublisher<SessionSnapshot, Never>? = nil,
        now: @escaping () -> Date = Date.init,
        playChime: (@MainActor () -> String)? = nil,
        record: @escaping @MainActor (String, String) -> Void
    ) {
        self.now = now
        self.playChime = playChime
        self.record = record
        // The model is main-actor bound, so its snapshots are published on the main thread.
        subscription = snapshots?.sink { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
    }

    /// Feed every snapshot change.
    func observe(_ snapshot: SessionSnapshot) {
        let wasWaiting = watch.waitingItemId
        switch watch.observe(itemId: snapshot.itemId, status: snapshot.status, at: now()) {
        case .firstAudio(let itemId, let milliseconds):
            record("firstAudioMs:\(itemId)", "\(milliseconds)")
            record("lastFirstAudioMs", "\(milliseconds)")
        case .ended(let itemId, let milliseconds, let status):
            record("lastPlaybackStartEnded", "\(itemId):\(status.rawValue):\(milliseconds)")
        case nil:
            break
        }
        guard let waiting = watch.waitingItemId, waiting != wasWaiting else { return }
        cueTask?.cancel()
        let delay = watch.cueDelay
        cueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.watch.takeCue(at: self.now()) else { return }
            self.record("lastPlaybackStartCue", "\(waiting):" + (self.playChime?() ?? self.playSoftChime()))
        }
    }

    private func playSoftChime() -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playback else { return "skipped:session_not_playback" }
        #endif
        do {
            let player = try AVAudioPlayer(data: PlaybackStartChime.wavData())
            player.volume = 1
            self.player = player
            return player.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
        }
    }
}
