import Foundation
import SessionKit
import SessionKitPersistence

/// What keeps a Make available offline run going while the app is open (#905): a wait that ends a
/// heat pause or a memory backoff by itself. The system progress card that once tried to carry a run
/// past the Lock Screen is gone (#2694): it ended as failed every time.
extension Gate1AppModel {
    /// Live playback leaves the renderer free. Apart from the memory backoff so a loop that a
    /// memory warning cancelled restarts and waits the backoff out (#1107).
    var playbackAllowsLibraryAudioPreparation: Bool {
        !snapshot.status.isPlaybackActive || isMediaPlaybackSnapshot
            || snapshot.preparedTextAudioStatus == "ready"
            || (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.canYieldRendererToLibrary == true
    }

    func idleForegroundPreparationTurn() { libraryAudioLoop.turns.stopped(.foreground) }

    /// The foreground preparation loop: runs passes while they have work, and after a pass that
    /// rendered nothing waits out a heat pause or a memory backoff and goes on. `pass` returns
    /// whether it has more work.
    func runForegroundPreparationLoop(pass: () async -> Bool) async {
        while !Task.isCancelled {
            if await pass() {
                await Task.yield()
            } else if await waitOutPreparationPause() {
                continue // the phone cooled or the backoff ended: a pause no longer ends the run (#905, #1107)
            } else {
                break
            }
        }
    }

    /// After a pass rendered nothing, waits out a heat pause or the backoff a memory warning
    /// starts, so the run carries on once the phone cools or the backoff is over. True: the pause
    /// ended and queued work is waiting, so run the pass again. False: nothing is waiting, the pass
    /// stopped for another reason, the wait ran out, or the loop was cancelled. Before this a
    /// pause ended the loop and nothing started it again, so a run stopped for heat or memory
    /// stayed stopped while the phone read nominal.
    func waitOutPreparationPause() async -> Bool {
        var waited = 0
        var heldByHeat = false
        var banner = false
        defer { isWaitingOutPreparationHeat = false }
        while !Task.isCancelled {
            let thermal = preparationSeams.deviceConditions().thermal
            heldByHeat = heldByHeat || PreparationChunkGate.isTooWarm(thermal)
            let step = OfflinePreparationRun.pauseWaitStep(
                thermal: thermal,
                memoryBackoffActive: preparationSeams.memoryBackoffActive(),
                waitedSeconds: waited,
                foregroundWorkWaiting: foregroundPreparationWorkIsWaiting()
            )
            let key = heldByHeat ? "preparationHeatWait" : "preparationMemoryWait"
            switch step {
            case .resume:
                diagnostics[key] = "resumed_after_\(waited)s"
                return true
            case .stop(let reason):
                if waited > 0 { diagnostics[key] = "stopped_\(reason.rawValue)_after_\(waited)s" }
                return false
            case .wait(let seconds):
                // The banner says the phone is cooling only while heat is what holds the run.
                isWaitingOutPreparationHeat = PreparationChunkGate.isTooWarm(thermal)
                if !banner {
                    banner = true
                    beginWaitingOutPreparationPause(key: key)
                }
                do {
                    try await preparationSeams.pause(seconds)
                } catch {
                    return false
                }
                waited += seconds
            }
        }
        return false
    }

    private func beginWaitingOutPreparationPause(key: String) {
        idleForegroundPreparationTurn() // the item stops showing as rendering while it waits
        refreshLibraryRowsInBackground()
        diagnostics[key] = "waiting"
    }

    private func foregroundPreparationWorkIsWaiting() -> Bool {
        guard let store, let jobs = try? store.loadAudioPreparationJobs() else { return false }
        return !LibraryAudioPreparationTurns.eligible(jobs, for: .foreground).isEmpty
    }
}
