import SessionKit
import SessionKitPersistence

extension Gate1AppModel {
    /// No transcription of this run exists yet at launch, so a Margin still "pending" lost its worker with the
    /// last run: settle it so it offers Retry instead of promising work (#942).
    func settleOrphanedTranscriptions(store: SQLiteSessionStore) {
        do {
            let settled = try store.settleOrphanedTranscriptions()
            if settled > 0 { diagnostics["orphanedTranscriptionsSettled"] = "\(settled)" }
        } catch {
            diagnostics["orphanedTranscriptionsSettled"] = "failed:\(error.localizedDescription)"
        }
    }

    /// A manual Retry failed. A Margin never transcribed would stay "pending" with the retry over; one that has
    /// words keeps them and its status (#942).
    func recordFailedRetry(of interjection: Interjection, failure: String) {
        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "retry_failed:\(failure)"
        diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
        run { engine in
            snapshot = try engine.transcriptionRetryFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
            refreshSelectedItem()
            refreshMarginRows()
        }
    }
}
