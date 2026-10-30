import Foundation
import SessionKit
import SessionKitPersistence

/// What keeps a Make available offline run going when the listener puts the phone down (#905): a
/// system progress task while the app is away, and a wait that ends a heat pause or a memory backoff by itself.
extension Gate1AppModel {
    // Read and driven by the continued-processing task and the heat wait.
    var isForegroundAudioPreparationRunning: Bool { libraryAudioLoop.isRunning }

    /// Ends the loop without the restart a plain cancel gets: iOS or the listener ended its background time.
    func stopForegroundAudioPreparation() {
        libraryAudioLoop.stopAndInvalidate()
    }

    /// Speech never shares the CPU with the Library, and a restored session waits for the listener (#2694).
    /// Apart from the memory backoff so a loop that a memory warning cancelled restarts and waits it out (#1107).
    var playbackAllowsLibraryAudioPreparation: Bool {
        libraryAudioLoop.renderPolicy.allowsRendering(.init(
            isPlaybackActive: snapshot.status.isPlaybackActive, isMedia: isMediaPlaybackSnapshot, hasSession: snapshot.itemId != nil
        ))
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

    /// Read off the main thread: the continued task asks once a second (#2508).
    func explicitPreparationJobs(including previous: [OfflinePreparationRun.Job] = []) async -> [OfflinePreparationRun.Job] {
        guard let store else { return previous }
        return (try? await StoreReader(store).read { OfflinePreparationRun.explicitJobs(store: $0, including: previous) }) ?? previous
    }

    /// Also covers expiry during a heat wait, when no renderer is there to record cancellation.
    func deferExplicitPreparation(_ requests: Set<OfflinePreparationRun.RequestKey>) {
        if let store, let jobs = try? store.loadAudioPreparationJobs() {
            for job in OfflinePreparationRecovery.interruptedJobs(jobs, requests: requests) {
                try? store.saveAudioPreparationJob(job)
            }
            Task { @MainActor [weak self] in await self?.refreshAudioPreparationPresentation() }
        }
        scheduleAudioPreparationBackgroundTask()
    }

    /// Asks iOS to keep the app running for a long run the listener just started. A no-op where
    /// background tasks don't exist.
    func requestContinuedAudioPreparationIfNeeded() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        installContinuedAudioPreparation() // here, not in init: keeps the hot file's size (#905)
        ContinuedAudioPreparationController.shared.requestIfNeeded()
        #endif
    }

    #if canImport(BackgroundTasks) && canImport(UIKit)
    private func installContinuedAudioPreparation() {
        ContinuedAudioPreparationController.shared.install(
            ContinuedAudioPreparationController.Hooks(
                jobs: { [weak self] previous in await self?.explicitPreparationJobs(including: previous) ?? [] },
                isRunning: { [weak self] in self?.isForegroundAudioPreparationRunning ?? false },
                isCoolingDown: { [weak self] in self?.isWaitingOutPreparationHeat ?? false },
                stop: { [weak self] in self?.stopForegroundAudioPreparation() },
                deferRemaining: { [weak self] requests in self?.deferExplicitPreparation(requests) },
                report: { [weak self] event in
                    guard let self else { return }
                    diagnostics["continuedAudioPreparation"] = event
                }
            )
        )
    }
    #endif
}
