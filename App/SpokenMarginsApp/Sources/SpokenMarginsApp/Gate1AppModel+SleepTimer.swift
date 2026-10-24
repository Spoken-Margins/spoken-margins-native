import AVFoundation
import Foundation
import SessionKit

/// The sleep timer, moved out of `Gate1AppModel.swift` (hot-file ratchet, #1538), now with a warning cue a minute
/// before the end and a fade over the last ten seconds (#1979). `SleepTimerPolicy` and `SleepTimerFadeTracker` in
/// SessionKit decide; this applies the result to the player.
extension Gate1AppModel {
    var sleepTimerIsActive: Bool {
        SleepTimerPolicy.isActive(sleepTimerState)
    }

    var sleepTimerDescription: String {
        SleepTimerPolicy.description(state: sleepTimerState, remainingSeconds: sleepTimerRemainingSeconds)
    }

    var canUseEndOfChapterSleepTimer: Bool {
        SleepTimerPolicy.endOfChapterTarget(chapters: selectedItem.mediaChapters, currentMediaTimeMs: snapshot.currentMediaTimeMs) != nil
    }

    func armSleepTimer(_ mode: SleepTimerMode) {
        guard let state = SleepTimerPolicy.arm(mode, now: Date(), chapters: selectedItem.mediaChapters, currentMediaTimeMs: snapshot.currentMediaTimeMs) else { return }
        sleepTimerState = state
        startSleepTimerTicker()
        reconcileSleepTimer(now: Date())
    }

    func extendSleepTimerBy15Minutes() {
        let now = Date()
        sleepTimerState = SleepTimerPolicy.extend(sleepTimerState, now: now)
        startSleepTimerTicker()
        reconcileSleepTimer(now: now) // sees the longer time left, so a faded volume comes back
    }

    func cancelSleepTimer() {
        sleepTimerFade.ticker?.cancel()
        sleepTimerFade.ticker = nil
        sleepTimerState = .inactive
        sleepTimerRemainingSeconds = nil
        applySleepTimerEffects(sleepTimerFade.tracker.reset())
    }

    private func startSleepTimerTicker() {
        sleepTimerFade.ticker?.cancel()
        sleepTimerFade.ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reconcileSleepTimer(now: Date())
                // Four steps a second while the volume falls, so the fade is smooth rather than ten drops.
                try? await Task.sleep(for: self.sleepTimerFade.tracker.isFading ? .milliseconds(250) : .seconds(1))
            }
        }
    }

    func reconcileSleepTimer(now: Date) {
        if let mode = SleepTimerPolicy.reconcile(
            state: &sleepTimerState, remainingSeconds: &sleepTimerRemainingSeconds,
            now: now, isRecording: snapshot.isRecording,
            currentMediaTimeMs: snapshot.currentMediaTimeMs, chapters: selectedItem.mediaChapters
        ) {
            if snapshot.status.isPlaybackActive { pause() }
            releaseOwnMarginReturn()
            cancelSleepTimer() // after the pause, so the volume comes back for the next time the listener plays
            reportConfirmation(SleepTimerPolicy.expiryConfirmation(mode: mode))
        } else {
            // Only what the listener hears is warned and faded: a paused source or a recording is left alone.
            let heard = snapshot.status.isPlaybackActive && !snapshot.isRecording
            let phase = heard
                ? SleepTimerPolicy.phase(state: sleepTimerState, now: now, currentMediaTimeMs: snapshot.currentMediaTimeMs, chapters: selectedItem.mediaChapters)
                : .running
            applySleepTimerEffects(sleepTimerFade.tracker.apply(phase))
        }
    }

    private func applySleepTimerEffects(_ effects: [SleepTimerFadeTracker.Effect]) {
        let usual: Double = mixesWithOtherAudio ? mixedPlaybackVolume : 1
        for effect in effects {
            switch effect {
            case .playWarningCue:
                diagnostics["sleepTimer.warningCue"] = sleepTimerFade.playWarningCue()
            case .setVolumeFactor(let factor):
                setSleepTimerPlaybackVolume(usual * factor)
            case .restoreVolume:
                setSleepTimerPlaybackVolume(usual)
            }
        }
    }

    private func setSleepTimerPlaybackVolume(_ volume: Double) {
        try? (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setPlaybackVolume(Float(volume))
    }
}

/// What the sleep timer keeps between ticks: its ticker, what it has already done for this countdown, and the
/// quiet cue that says a minute is left.
@MainActor
final class SleepTimerFadeController {
    var ticker: Task<Void, Never>?
    var tracker = SleepTimerFadeTracker()
    private var cuePlayer: AVAudioPlayer?

    /// A soft chime under the listener's own audio. Returns what happened, for Diagnostics.
    func playWarningCue() -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playback else { return "skipped:session_not_playback" }
        #endif
        do {
            let player = try AVAudioPlayer(data: PlaybackStartChime.wavData())
            player.volume = 0.35
            cuePlayer = player
            return player.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
        }
    }
}
