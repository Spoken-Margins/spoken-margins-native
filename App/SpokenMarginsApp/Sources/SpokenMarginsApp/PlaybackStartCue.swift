import AVFoundation
import Combine
import SessionKit

/// Watches playback starts for #357. Silence while a voice warms up reads as failure when listening eyes-free, so
/// a start that is still silent after 0.8 s gets a short soft chime. Each start's time to first audio goes into
/// diagnostics as `firstAudioMs:<item id>`.
///
/// The chime never configures the audio session: it plays only when the start has already put the session in its
/// `.playback` category, and otherwise the start stays silent, as before.
///
/// The model checks the player only every 500 ms, so a snapshot can still say "starting" after speech has begun.
/// Before chiming, the cue asks for a fresh check (`checkNow`), so the chime doesn't land on the first words.
/// Times to first audio are measured to the snapshot that shows playing, which can be up to 500 ms late.
@MainActor
final class PlaybackStartCue: ObservableObject {
    private var watch = PlaybackStartWatch()
    private var cueTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let now: () -> Date
    /// Tests replace the chime; it returns what the cue did.
    private let playChime: (@MainActor () -> String)?
    /// Brings the snapshot up to date with the player before the cue decides; in the app, the model's lifecycle sync.
    private let checkNow: (@MainActor () -> Void)?
    /// Writes one diagnostic (key, value), normally into the model's diagnostics.
    private let record: @MainActor (String, String) -> Void

    private var subscription: AnyCancellable?

    /// `snapshots` is the model's `$snapshot`. Subscribing here rather than from a view keeps the cue working when
    /// playback starts with no window attached (a Live Activity or an intent after a background launch).
    init(
        snapshots: AnyPublisher<SessionSnapshot, Never>? = nil,
        now: @escaping () -> Date = Date.init,
        playChime: (@MainActor () -> String)? = nil,
        checkNow: (@MainActor () -> Void)? = nil,
        record: @escaping @MainActor (String, String) -> Void
    ) {
        self.now = now
        self.playChime = playChime
        self.checkNow = checkNow
        self.record = record
        // The model is main-actor bound, so its snapshots are published on the main thread.
        subscription = snapshots?.sink { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
    }

    /// The app's cue: it follows the model, checks the player before chiming, and writes through `pinned`, so
    /// Refresh Diagnostics doesn't drop the measurements (audit of #580).
    convenience init(model: Gate1AppModel, pinned: PinnedDiagnostics) {
        self.init(snapshots: model.$snapshot.eraseToAnyPublisher(),
                  checkNow: { [weak model] in model?.syncPlaybackProgressForLifecycle() },
                  record: { key, value in pinned.set(key, value) })
    }

    /// Feed every snapshot change.
    func observe(_ snapshot: SessionSnapshot) {
        let wasWaiting = watch.waitingItemId
        for outcome in watch.observe(itemId: snapshot.itemId, status: snapshot.status, at: now()) {
            switch outcome {
            case .firstAudio(let itemId, let milliseconds):
                record("firstAudioMs:\(itemId)", "\(milliseconds)")
                record("lastFirstAudioMs", "\(milliseconds)")
            case .ended(let itemId, let milliseconds, let status):
                record("lastPlaybackStartEnded", "\(itemId):\(status.rawValue):\(milliseconds)")
            }
        }
        guard let waiting = watch.waitingItemId, waiting != wasWaiting else { return }
        cueTask?.cancel()
        let delay = watch.cueDelay
        cueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.checkNow?()
            guard !Task.isCancelled, self.watch.takeCue(at: self.now()) else { return }
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
