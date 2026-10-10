import Foundation
import SessionKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The shared Margin's voice transport: pause and resume, the health check on the player (#941), Retry,
/// and the system Now Playing line. Moved out of `Gate1AppModel.swift` to keep that file under its size
/// ceiling (scripts/hot_file_ratchet.py); the first three functions changed only for #941.
extension Gate1AppModel {
    func setImportedCommentaryPaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard playingImportedCommentary != nil else { return }
        if importedCommentaryPhase.isFailed {
            if !paused { retryImportedCommentary() }
            return
        }
        guard let player = interjectionAudioPlayer else { return }
        if paused {
            player.pause()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        } else {
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                player.playImmediately(atRate: Float(playingInterjectionAudioRate))
            } catch {
                reportFailure(error, context: "Shared Margin resume failed")
                return
            }
        }
        importedCommentaryIsPaused = paused
        importedCommentaryHealth?.setUserPaused(paused, at: ProcessInfo.processInfo.systemUptime)
        if let phase = importedCommentaryHealth?.phase { importedCommentaryPhase = phase }
        publishImportedCommentaryNowPlaying()
        #endif
    }

    /// Feeds the player's own report into the health rule and shows what it concludes (#941).
    func observeImportedCommentary(playerFailed: Bool, clockSeconds: Double, playerAtRest: Bool) {
        guard var health = importedCommentaryHealth else { return }
        let phase = health.observe(playerFailed: playerFailed, clockSeconds: clockSeconds, playerAtRest: playerAtRest, at: ProcessInfo.processInfo.systemUptime)
        importedCommentaryHealth = health
        if phase != importedCommentaryPhase { importedCommentaryPhase = phase }
        if phase.isFailed { failImportedCommentaryPlayback() }
    }

    /// The voice cannot play. Stops the player and the polling, keeps the Margin on screen with Retry and
    /// Return to Source, and tells the system it is not playing. The Margin stays new; the source-resume
    /// intent is untouched, so Return to Source or a Retry that then ends still resumes it once.
    func failImportedCommentaryPlayback() {
        #if canImport(AVFoundation)
        interjectionAudioCompletionTask?.cancel()
        interjectionAudioCompletionTask = nil
        interjectionAudioPlayer?.pause()
        interjectionAudioPlayer?.replaceCurrentItem(with: nil)
        interjectionAudioPlayer = nil
        importedCommentaryIsPaused = false
        publishImportedCommentaryNowPlaying()
        #endif
    }

    /// Retry after a failure: a fresh player, item and health record for the same Margin.
    func retryImportedCommentary() {
        guard let prompt = playingImportedCommentary, importedCommentaryPhase.isFailed else { return }
        listenToImportedCommentary(prompt)
    }

    func publishImportedCommentaryNowPlaying() {
        #if canImport(AVFoundation)
        guard !mixesWithOtherAudio, let prompt = playingImportedCommentary else { return }
        let player = interjectionAudioPlayer
        importedMarginRemoteControls.publish(
            sender: prompt.senderLabel, elapsed: player?.currentTime().seconds ?? 0,
            duration: player?.currentItem?.duration.seconds ?? .nan,
            rate: importedCommentaryHealth?.nowPlayingRate(playerRate: Double(player?.rate ?? 0)) ?? 0
        )
        #endif
    }
}
