import Foundation
import SessionKit
import SessionKitPersistence

/// The model's face to `TextSceneMapPreparer` (#3450): what it tells the listener when a run ends.
extension Gate1AppModel: TextSceneMapPreparerHost {
    func textSceneSummariesDidFinish(itemId: String, outcome: TextSceneSummaryOutcome) {
        diagnostics["textSceneSummaries:\(itemId)"] = outcome.diagnostic
        guard itemId == activeItemId else { return }
        if case .summarised = outcome {
            refreshSelectedItemInBackground()
            updateSkimAvailability()
        }
        if case .cancelled = outcome { return }
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
