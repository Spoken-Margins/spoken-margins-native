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
/// Before chiming, the cue asks for a fresh check (`checkNow`), so the chime doesn't land on the first words. In the
/// app that check is one extra regular progress tick, so shared Margins and other per-tick work still see every step.
/// Times to first audio run from the listener's request (the snapshot's `playbackRequestedAt`) to the snapshot that
/// shows playing, which can be up to 500 ms late.
///
/// The chime stops as soon as its start resolves, so it never runs over the first words. Since the regular check can
/// be 500 ms late, the cue asks for one more check part-way through the chime (audit of #580).
///
/// One chime and then silence still reads as a stall when the wait is long, so a start that is still silent
/// `PlaybackWaitingCue.delay` after the chime also gets a quiet repeating waiting sound (three soft pops, every
/// `PlaybackWaitingCue.period`). It is scheduled on the audio clock at the moment the chime plays and loops in the
/// audio player, so it keeps going after the app leaves the screen. It stops with the chime: on the first word, a
/// pause, a failure or another item, and it gives up after `PlaybackWaitingCue.limit`.
@MainActor
final class PlaybackStartCue: ObservableObject {
    private var watch = PlaybackStartWatch()
    private var cueTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var waitingPlayer: AVAudioPlayer?
    private let now: () -> Date
    private let waitingCueDelay: TimeInterval
    private let waitingCuePeriod: TimeInterval
    private let waitingCueLimit: TimeInterval
    /// Tests replace the chime; it returns what the cue did.
    private let playChime: (@MainActor () -> String)?
    /// Tests replace scheduling the waiting sound (seconds from now to its first repetition); it returns what the cue did.
    private let scheduleWaitingCue: (@MainActor (TimeInterval) -> String)?
    /// Tests replace stopping the chime and the waiting sound.
    private let stopChimeOverride: (@MainActor () -> Void)?
    /// Brings the snapshot up to date with the player before the cue decides; in the app, one model progress tick.
    private let checkNow: (@MainActor () -> Void)?
    /// Writes one diagnostic (key, value), normally into the model's diagnostics.
    private let record: @MainActor (String, String) -> Void

    private var subscription: AnyCancellable?

    /// `snapshots` is the model's `playbackClock.snapshots`. Subscribing here rather than from a view keeps the cue working when
    /// playback starts with no window attached (a Live Activity or an intent after a background launch).
    init(
        snapshots: AnyPublisher<SessionSnapshot, Never>? = nil,
        now: @escaping () -> Date = Date.init,
        playChime: (@MainActor () -> String)? = nil,
        scheduleWaitingCue: (@MainActor (TimeInterval) -> String)? = nil,
        waitingCueDelay: TimeInterval = PlaybackWaitingCue.delay,
        waitingCuePeriod: TimeInterval = PlaybackWaitingCue.period,
        waitingCueLimit: TimeInterval = PlaybackWaitingCue.limit,
        stopChime: (@MainActor () -> Void)? = nil,
        checkNow: (@MainActor () -> Void)? = nil,
        record: @escaping @MainActor (String, String) -> Void
    ) {
        self.now = now
        self.playChime = playChime
        self.scheduleWaitingCue = scheduleWaitingCue
        self.waitingCueDelay = waitingCueDelay
        self.waitingCuePeriod = waitingCuePeriod
        self.waitingCueLimit = waitingCueLimit
        self.stopChimeOverride = stopChime
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
        self.init(snapshots: model.playbackClock.snapshots.eraseToAnyPublisher(),
                  checkNow: { [weak model] in model?.tickPlaybackProgress() },
                  record: { key, value in pinned.set(key, value) })
    }

    /// Feed every snapshot change.
    func observe(_ snapshot: SessionSnapshot) {
        let startsBefore = watch.startCount
        let outcomes = watch.observe(itemId: snapshot.itemId, targetId: snapshot.targetId, status: snapshot.status,
                                     requestedAt: snapshot.playbackRequestedAt, at: now())
        // A start that resolved (audio began, or it was paused, failed or replaced) ends its chime (audit of #580).
        if !outcomes.isEmpty || watch.startCount != startsBefore { stopChime() }
        for outcome in outcomes {
            switch outcome {
            case .firstAudio(let itemId, let milliseconds):
                record("firstAudioMs:\(itemId)", "\(milliseconds)")
                record("lastFirstAudioMs", "\(milliseconds)")
            case .ended(let itemId, let milliseconds, let status):
                record("lastPlaybackStartEnded", "\(itemId):\(status.rawValue):\(milliseconds)")
            }
        }
        guard let waiting = watch.waitingItemId else {
            // The start resolved: no cue, and no extra check (audit of #580).
            cueTask?.cancel()
            cueTask = nil
            return
        }
        guard watch.startCount != startsBefore else { return } // the same start continues; its cue stays scheduled
        cueTask?.cancel()
        // The cue is due 0.8 s after the request, not after the start was published (audit of #580).
        let delay = watch.cueWait(at: now()) ?? watch.cueDelay
        cueTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.checkNow?()
            guard !Task.isCancelled, self.watch.takeCue(at: self.now()) else { return }
            let result = self.playChime?() ?? self.playSoftChime()
            self.record("lastPlaybackStartCue", "\(waiting):" + result)
            guard result == "played" else { return }
            // The waiting sound is placed on the audio clock now, so it still sounds if the app is in the background.
            let chimedAt = ContinuousClock.now
            let waitingResult = self.scheduleWaitingCue?(self.waitingCueDelay) ?? self.scheduleWaitingLoop(after: self.waitingCueDelay)
            self.record("lastWaitingCue", "\(waiting):" + waitingResult)
            // Speech that begins under the chime stops it here, not at the next regular check.
            try? await Task.sleep(for: .seconds(Self.checkDuringChime))
            guard !Task.isCancelled else { return }
            self.checkNow?()
            guard waitingResult == "scheduled" else { return }
            await self.keepWaitingCueHonest(for: waiting, chimedAt: chimedAt)
        }
    }

    /// Checks the player just before and just into each repetition, so a repetition doesn't start or run on after
    /// the first words (the regular check can be 500 ms late), and ends the sound when the start has hung too long.
    private func keepWaitingCueHonest(for itemId: String, chimedAt: ContinuousClock.Instant) async {
        var repetition = 0
        while !Task.isCancelled {
            let begins = chimedAt + .seconds(waitingCueDelay + Double(repetition) * waitingCuePeriod)
            if begins - chimedAt >= .seconds(waitingCueLimit) {
                stopChime()
                record("lastWaitingCue", "\(itemId):gave_up")
                return
            }
            try? await Task.sleep(until: begins - .milliseconds(100), clock: .continuous)
            guard !Task.isCancelled else { return }
            checkNow?()
            try? await Task.sleep(until: begins + .milliseconds(250), clock: .continuous)
            guard !Task.isCancelled else { return }
            checkNow?()
            repetition += 1
        }
    }

    /// The end of the chime's first note.
    static let checkDuringChime = PlaybackStartChime.notes[0].seconds

    private func stopChime() {
        if let stopChimeOverride { stopChimeOverride(); return }
        player?.stop()
        player = nil
        waitingPlayer?.stop() // also cancels a repetition that is scheduled but hasn't begun
        waitingPlayer = nil
    }

    private func scheduleWaitingLoop(after delay: TimeInterval) -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playback else { return "skipped:session_not_playback" }
        #endif
        do {
            let player = try AVAudioPlayer(data: PlaybackWaitingCue.wavData())
            player.numberOfLoops = -1
            player.volume = 1
            player.prepareToPlay()
            self.waitingPlayer = player
            return player.play(atTime: player.deviceCurrentTime + delay) ? "scheduled" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
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
