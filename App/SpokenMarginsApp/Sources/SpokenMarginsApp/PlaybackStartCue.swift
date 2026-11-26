import AVFoundation
import Combine
import SessionKit
import SessionKitAudio

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
/// The check part-way through the chime still leaves the second note open to speech that begins after it, so each
/// audio client also reports its first sound (`FirstAudioSignals`, #842). A signal for the open start's own target
/// cancels the pending cue and fades a chime or waiting sound that is already sounding out over 20 ms, so neither
/// runs over the first word. It changes no playback state: the engine's snapshot still closes the start and times
/// `firstAudioMs`.
///
/// One chime and then silence still reads as a stall when the wait is long, so a start that is still silent
/// `PlaybackWaitingCue.delay` after the chime also gets a quiet repeating waiting sound (three soft pops, every
/// `PlaybackWaitingCue.period`). It is scheduled on the audio clock at the moment the chime plays and loops in the
/// audio player, so it keeps going after the app leaves the screen. It stops with the chime: on the first word, a
/// pause, a failure or another item, and it gives up after `PlaybackWaitingCue.limit`.
@MainActor
final class PlaybackStartCue: ObservableObject {
    private var watch = PlaybackStartWatch()
    /// The pending chime and waiting-sound checks of the start being watched. Tests await it to know the cue is done.
    private(set) var cueTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var waitingPlayer: AVAudioPlayer?
    /// A stand-in chime (`playChime`) is sounding. Only tests set it; the real chime is known by its players.
    private var chimeSounding = false
    /// A first sound cancelled this start's cue; if the engine moves the start to another target, schedule it again.
    private var cueNeededAfterRetarget = false
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
    private var firstAudioSubscription: AnyCancellable?

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
        firstAudio: AnyPublisher<String, Never>? = nil,
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
        // The hub's receive(on: main) delivers on the main thread, as the snapshots are.
        firstAudioSubscription = firstAudio?.sink { [weak self] targetId in
            MainActor.assumeIsolated { self?.firstAudioHeard(targetId: targetId) }
        }
    }

    /// The app's cue: it follows the model, checks the player before chiming, and writes through `pinned`, so
    /// Refresh Diagnostics doesn't drop the measurements (audit of #580).
    convenience init(model: Gate1AppModel, pinned: PinnedDiagnostics) {
        self.init(snapshots: model.playbackClock.snapshots.eraseToAnyPublisher(),
                  checkNow: { [weak model] in model?.tickPlaybackProgress() },
                  firstAudio: FirstAudioSignals.shared.heard.receive(on: DispatchQueue.main).eraseToAnyPublisher(),
                  record: { key, value in pinned.set(key, value) })
    }

    /// Feed every snapshot change.
    func observe(_ snapshot: SessionSnapshot) {
        let startsBefore = watch.startCount
        let targetBefore = watch.waitingTargetId
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
            cueNeededAfterRetarget = false
            return
        }
        guard watch.startCount != startsBefore else {
            // The same start continues and its cue stays scheduled, with one exception: a first sound ended that cue,
            // and the engine has since moved the start to another target (narration falling back to live speech).
            // That target has not been heard, so the watch gives the start its cue again, and a task must take it (#842).
            if cueNeededAfterRetarget, watch.waitingTargetId != targetBefore {
                cueNeededAfterRetarget = false
                scheduleCue(waiting: waiting)
            }
            return
        }
        cueNeededAfterRetarget = false
        scheduleCue(waiting: waiting)
    }

    /// Schedules the cue for the open start: due 0.8 s after the request, then the chime and the waiting sound.
    private func scheduleCue(waiting: String) {
        cueTask?.cancel()
        // The cue is due 0.8 s after the request, not after the start was published (audit of #580).
        let delay = watch.cueWait(at: now()) ?? watch.cueDelay
        cueTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.checkNow?()
            guard !Task.isCancelled, self.watch.takeCue(at: self.now()) else { return }
            let result = MainThreadOperationLabels.shared.scoped("playbackStartChime") { self.playChime?() ?? self.playSoftChime() }
            self.record("lastPlaybackStartCue", "\(waiting):" + result)
            guard result == "played" else { return }
            self.chimeSounding = self.playChime != nil
            // The waiting sound is placed on the audio clock now, so it still sounds if the app is in the background.
            let chimedAt = ContinuousClock.now
            let waitingResult = MainThreadOperationLabels.shared.scoped("playbackWaitingCue") {
                self.scheduleWaitingCue?(self.waitingCueDelay) ?? self.scheduleWaitingLoop(after: self.waitingCueDelay)
            }
            self.record("lastWaitingCue", "\(waiting):" + waitingResult)
            // Speech that begins under the chime stops it here, not at the next regular check.
            try? await Task.sleep(for: .seconds(Self.checkDuringChime))
            guard !Task.isCancelled else { return }
            self.checkNow?()
            guard waitingResult == "scheduled" else { return }
            await self.keepWaitingCueHonest(for: waiting, chimedAt: chimedAt)
        }
    }

    /// An audio client says sound began for `targetId` (#842). Only a start that is open for that target is
    /// affected: its pending cue is cancelled, and a chime or waiting sound already sounding fades out over 20 ms,
    /// before the first word. A late signal from an earlier start, or one with no open start, changes nothing.
    func firstAudioHeard(targetId: String) {
        guard let itemId = watch.waitingItemId, watch.firstAudioHeard(targetId: targetId) else { return }
        cueTask?.cancel()
        cueTask = nil
        // If the start moves to another target before it resolves, that target gets a cue (see `observe`).
        cueNeededAfterRetarget = true
        guard let stopped = stopForFirstAudio() else { return }
        if stopped { record("lastPlaybackStartCue", "\(itemId):stopped_by_first_audio") }
    }

    /// Stops what is sounding for a first-audio signal. Returns nil when nothing was sounding, so a start whose cue
    /// never played keeps its diagnostic as it was.
    private func stopForFirstAudio() -> Bool? {
        if let stopChimeOverride {
            guard chimeSounding else { return nil }
            stopChimeOverride()
            chimeSounding = false
            return true
        }
        // Local copies and nil fields at once, so a later start's chime, or the next snapshot's `stopChime`, can't
        // touch these players.
        let sounding = [player, waitingPlayer].compactMap { $0 }
        player = nil
        waitingPlayer = nil
        guard !sounding.isEmpty else { return nil }
        for sound in sounding { sound.setVolume(0, fadeDuration: Self.firstAudioFade) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.firstAudioFade + 0.01))
            for sound in sounding { sound.stop() }
        }
        return true
    }

    /// Long enough that cutting a sine mid-wave doesn't click, far shorter than a word's onset.
    static let firstAudioFade: TimeInterval = 0.02

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
        chimeSounding = false
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
            return "skipped:\(SafeErrorText.describe(error))"
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
            return "skipped:\(SafeErrorText.describe(error))"
        }
    }
}
