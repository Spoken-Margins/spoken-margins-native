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

    /// The Library renders only while the listener isn't hearing on-device speech, and not right after
    /// a relaunch that restored a speech session (#2694). Apart from the memory backoff so a loop that a
    /// memory warning cancelled restarts and waits the backoff out (#1107).
    var playbackAllowsLibraryAudioPreparation: Bool {
        LibraryAudioPreparationPlayback.allows(
            isMediaPlayback: isMediaPlaybackSnapshot,
            isPlaybackActive: snapshot.status.isPlaybackActive,
            holdsForRestoredSpeech: holdsLibraryAudioForRestoredSpeech
        )
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

    func explicitPreparationJobs(including previous: [OfflinePreparationRun.Job] = []) -> [OfflinePreparationRun.Job] {
        guard let store, let stored = try? store.loadAudioPreparationJobs() else { return previous }
        let allJobs = stored.filter { !$0.isCancelled && $0.policy == .explicit }.map { job in
            let manifest = try? store.loadPreparedAudioManifest(id: job.manifestId)
            return OfflinePreparationRun.Job(
                id: job.id, manifestId: job.manifestId,
                requestedAt: job.requestedAt, policy: job.policy,
                state: manifest?.state ?? .failed,
                completedChunks: manifest?.committedChunkCount ?? job.nextChunkIndex,
                plannedChunks: manifest?.plannedChunkCount ?? 0
            )
        }
        // Old failures aren't part of a new run. A failure this banner saw happen stays in it.
        let tracked = OfflinePreparationRun.openExplicitRequests(allJobs).union(previous.map {
            OfflinePreparationRun.RequestKey(jobId: $0.id, requestedAt: $0.requestedAt)
        })
        let jobs = allJobs.filter { tracked.contains(.init(jobId: $0.id, requestedAt: $0.requestedAt)) }
        let current = Set(jobs.map { OfflinePreparationRun.RequestKey(jobId: $0.id, requestedAt: $0.requestedAt) })
        return jobs + previous.filter {
            !current.contains(.init(jobId: $0.id, requestedAt: $0.requestedAt))
        }.map { job in
            OfflinePreparationRun.resolvingRemovedJob(job, manifest: try? store.loadPreparedAudioManifest(id: job.manifestId))
        }
    }

    /// Also covers expiry during a heat wait, when no renderer is there to record cancellation.
    func deferExplicitPreparation(_ requests: Set<OfflinePreparationRun.RequestKey>) {
        if let store, let jobs = try? store.loadAudioPreparationJobs() {
            for job in OfflinePreparationRecovery.interruptedJobs(jobs, requests: requests) {
                try? store.saveAudioPreparationJob(job)
            }
            try? refreshAudioPreparationPresentation(store: store)
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
                jobs: { [weak self] previous in self?.explicitPreparationJobs(including: previous) ?? [] },
                canPrepare: { [weak self] in self?.canPrepareLibraryAudio ?? false },
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
