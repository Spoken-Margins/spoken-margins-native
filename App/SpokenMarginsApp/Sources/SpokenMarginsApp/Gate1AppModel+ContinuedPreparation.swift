import Foundation
import SessionKit
import SessionKitPersistence

/// What keeps a Make available offline run going when the listener puts the phone down (#905): a
/// system progress task while the app is away, and a wait that ends a heat pause by itself.
extension Gate1AppModel {
    /// After a pass rendered nothing, waits out a heat pause so the run carries on once the phone
    /// cools. True: it cooled and queued work is waiting, so run the pass again. False: nothing is
    /// waiting, the pass stopped for a reason other than heat, the wait ran out, or the loop was
    /// cancelled. Before this a heat pause ended the loop and nothing started it again, so a run
    /// stopped for heat stayed stopped while the phone read nominal.
    func waitOutPreparationHeat() async -> Bool {
        var waited = 0
        defer { isWaitingOutPreparationHeat = false }
        while !Task.isCancelled {
            let step = OfflinePreparationRun.heatWaitStep(
                thermal: preparationSeams.deviceConditions().thermal,
                waitedSeconds: waited,
                foregroundWorkWaiting: foregroundPreparationWorkIsWaiting()
            )
            switch step {
            case .resume:
                diagnostics["preparationHeatWait"] = "resumed_after_\(waited)s"
                return true
            case .stop(let reason):
                if waited > 0 { diagnostics["preparationHeatWait"] = "stopped_\(reason.rawValue)_after_\(waited)s" }
                return false
            case .wait(let seconds):
                if !isWaitingOutPreparationHeat { beginWaitingOutPreparationHeat() }
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

    private func beginWaitingOutPreparationHeat() {
        isWaitingOutPreparationHeat = true
        idleForegroundPreparationTurn() // the item stops showing as rendering while it waits
        if let store { try? refreshLibraryRows(store: store) }
        diagnostics["preparationHeatWait"] = "waiting"
    }

    private func foregroundPreparationWorkIsWaiting() -> Bool {
        guard let store, let jobs = try? store.loadAudioPreparationJobs() else { return false }
        return !LibraryAudioPreparationTurns.eligible(jobs, for: .foreground).isEmpty
    }

    func explicitPreparationJobs() -> [OfflinePreparationRun.Job] {
        audioPreparationQueue.map {
            OfflinePreparationRun.Job(
                policy: $0.policy,
                state: $0.state,
                completedChunks: $0.completedChunkCount,
                plannedChunks: $0.plannedChunkCount
            )
        }
    }

    /// Asks iOS to keep the app running for a long run the listener just started. A no-op where
    /// background tasks don't exist.
    func requestContinuedAudioPreparationIfNeeded() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        ContinuedAudioPreparationController.shared.requestIfNeeded()
        #endif
    }

    #if canImport(BackgroundTasks) && canImport(UIKit)
    func installContinuedAudioPreparation() {
        ContinuedAudioPreparationController.shared.install(
            ContinuedAudioPreparationController.Hooks(
                jobs: { [weak self] in self?.explicitPreparationJobs() ?? [] },
                isRunning: { [weak self] in self?.isForegroundAudioPreparationRunning ?? false },
                isCoolingDown: { [weak self] in self?.isWaitingOutPreparationHeat ?? false },
                cancel: { [weak self] in self?.cancelForegroundAudioPreparation() },
                report: { [weak self] event in
                    guard let self else { return }
                    diagnostics["continuedAudioPreparation"] = event
                }
            )
        )
    }
    #endif
}
