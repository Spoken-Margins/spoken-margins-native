import Foundation
import SessionKit
import SessionKitPersistence

/// The model's face to `TextSceneMapPreparer` (#3450): what it tells the listener when a run ends.
extension Gate1AppModel: TextSceneMapPreparerHost {
    func textSceneSummariesDidFinish(itemId: String, outcome: TextSceneSummaryOutcome, policy: PreparationJobPolicy) {
        diagnostics["textSceneSummaries:\(itemId)"] = outcome.diagnostic
        // The background pass settles an item once a run ended on it for good, so a charge isn't spent on it again.
        if policy == .whileCharging, outcome.settlesBackgroundRun { TextSceneBackgroundMemo.settle(itemId) }
        guard itemId == activeItemId else { return }
        // A paused or cancelled run saved the scenes it had written, so the screen and Skim read them now (#3461).
        switch outcome {
        case .summarised, .paused, .audioPaused, .modelStopped, .cancelled, .keptOtherMap, .failed:
            refreshSelectedItemInBackground()
            updateSkimAvailability()
        case .nothingToSummarise, .noSummaryAccepted:
            break
        }
        objectWillChange.send()
        if case .cancelled = outcome { return }
        if policy == .whileCharging { return } // a background run doesn't speak up on whatever the listener is doing
        reportConfirmation(outcome.message)
    }
}

extension Gate1AppModel {
    /// Prepare Listening Map on an article or PDF: the rule-based chapters first, then the on-device model writes each
    /// scene's summary for Skim, or the listener is told it can't and keeps the chapters (#3450). Moved from the
    /// model unchanged except for that last step.
    func generateLocalListeningMap(confirmation: String) {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            diagnostics["lastListeningMapMode"] = "local_deterministic"
            schedulePrewarmAfterPreparedTextChange(itemId: activeItemId)
            reportConfirmation("\(confirmation) \(textSceneMapPreparer.prepare(itemId: activeItemId).note)")
        }
    }
}

extension Gate1AppModel {
    /// True while this item's scene summaries are being written.
    var isWritingSceneSummaries: Bool { textSceneMapPreparer.itemId == activeItemId }

    /// The item screen's button for an article or PDF that already has chapters: write the scene summaries, or continue
    /// after a run that failed, was cancelled, paused for heat, or was cut off (#3461). Saved scenes are kept.
    func writeSceneSummaries() {
        reportConfirmation(textSceneMapPreparer.prepare(itemId: activeItemId).note)
        objectWillChange.send()
    }

    /// One article or PDF's scene summaries in the background pass, which iOS runs only on external power and which
    /// needs the While Charging setting for episode maps (#3461). Returns nil when there is nothing to do right now, so
    /// the pass goes on to its other work; otherwise how the pass went. Fetches nothing: the text is the item's own.
    func performBackgroundTextSceneSummaryPass() async -> BackgroundPreparationWorkResult? {
        guard automaticEpisodeMapPreparationPolicy == .whileCharging,
              let store,
              textSceneMapPreparer.task == nil,
              localFoundationModelAvailable,
              EpisodeMapRunGuard.yieldReason(conditions: episodeMapDeviceConditions(), policy: .whileCharging) == nil
        else { return nil }
        let ids = libraryItems.map(\.id)
        let settled = TextSceneBackgroundMemo.settled()
        let next = try? await Gate1AppModel.offMain {
            TextSceneSummaryCandidates.next(itemIds: ids, settled: settled, store: store)
        }
        guard let itemId = next ?? nil, case .started = textSceneMapPreparer.prepare(itemId: itemId, policy: .whileCharging),
              let task = textSceneMapPreparer.task else { return nil }
        let preparer = textSceneMapPreparer
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // iOS ended the background time: the run stops at the next scene and keeps what it wrote.
            Task { @MainActor in preparer.cancel(itemId: itemId) }
        }
        // A run that ended for good moves on to the next item; one that stopped (heat, cancel, error) waits for the next pass.
        return TextSceneBackgroundMemo.settled().contains(itemId) ? .continueNow : .retryLater
    }
}

/// The items a background run has already ended on for good (finished, or nothing the model could summarise), kept so
/// the charging pass doesn't pick them again. The listener's own tap is not affected (#3461).
enum TextSceneBackgroundMemo {
    private static let key = "textSceneSummaries.backgroundSettled"

    static func settled(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func settle(_ itemId: String, _ defaults: UserDefaults = .standard) {
        defaults.set(Array(settled(defaults).union([itemId])).sorted(), forKey: key)
    }
}
