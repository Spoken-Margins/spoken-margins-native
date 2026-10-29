import Foundation
import SessionKit
import SessionKitPersistence

/// AI job recovery and local summary execution. Moved out of `Gate1AppModel.swift` (#960). Nothing here talks to a
/// remote AI service (#2845); the file keeps its name so the main-thread-reads baseline paths stay stable.
extension Gate1AppModel {
    func recoverInterruptedAIJobs(store: SQLiteSessionStore, rows: [LibraryItemRow]) throws {
        var recovered = 0
        for row in rows {
            for session in try store.loadSessions(itemId: row.id) {
                for var job in try store.loadAIJobs(sessionId: session.id) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = job.providerType != "apple_foundation_on_device"
                    job.status = remoteJobDisabled ? "failed" : "retryable"
                    job.lastError = remoteJobDisabled
                        ? "remote_provider_disabled_by_feature_flag"
                        : "app_terminated_during_stream"
                    try store.updateAIJob(job)
                    if let turnId = job.turnId,
                       var turn = try store.loadTurns(sessionId: session.id).first(where: { $0.id == turnId && $0.status == "streaming" }) {
                        turn.status = "failed_partial"
                        try store.saveTurn(turn)
                    }
                    recovered += 1
                }
            }
        }
        diagnostics["recoveredInterruptedAIJobs"] = "\(recovered)"
    }

    func submitLocalSummary(itemId: String, turnId: String, contexts: [String], retryContext: LocalSummaryRetryContext) {
        statusMessage = "Summarizing Margins on device."
        lastError = nil
        // The session this summary belongs to: a failure that arrives after another session
        // became active settles this one's job and turn, not that session's (#1469).
        let originSessionId = snapshot.sessionId
        guard let submissionEngine = engine else { return }
        let origin: LocalSummaryRequestOrigin
        do { origin = try submissionEngine.localSummaryRequestOrigin(itemId: itemId, turnId: turnId) }
        catch { reportFailure(error, context: "Summary request is no longer pending"); return }
        Task {
            do {
                let client = localFoundationModelClient
                let partials = try await SummaryPartialsReducer.reduce(contexts: contexts) { context in
                    try await client.summarizeInterjections(context: context)
                }
                guard let response = partials.first, !response.isEmpty else {
                    throw LocalFoundationModelError.emptyResponse
                }
                // Settings can replace the runtime while the provider is suspended. Publish through
                // the installed engine; only the immutable request address survives the await.
                guard let engine else { return }
                snapshot = try engine.completeLocalSummary(origin: origin, content: response)
                diagnostics["lastSummaryMode"] = "apple_foundation_on_device"
                // Save a late result without replacing another item's controls, status or autoplay queue.
                guard origin.matchesPlayback(snapshot), selectedItem.id == origin.itemId else { return }
                let completedCurrentAudio = syncPlaybackProgressBeforeGeneratedTurnDecision(engine: engine)
                try autoPlayCompletedTurn(
                    kind: "interjection_summary",
                    turnId: turnId,
                    engine: engine,
                    completedCurrentAudio: completedCurrentAudio
                )
                diagnostics["lastSummaryMode"] = "apple_foundation_on_device"
                refreshSelectedItem()
                reportConfirmation("On-device summary saved and queued after the current source.")
            } catch is LocalSummaryRequestOrigin.Discarded {
                diagnostics["lastSummaryMode"] = "apple_foundation_discarded"
            } catch {
                diagnostics["lastSummaryMode"] = "apple_foundation_failed"
                diagnostics["lastLocalSummaryErrorType"] = String(reflecting: type(of: error))
                let presentation = LocalSummaryFailurePresentation(errorDescription: error.localizedDescription)
                markProviderFailure(
                    String(describing: error),
                    userMessage: presentation.detailMessage,
                    itemId: itemId,
                    retry: .init(key: "summary") { [weak self] in self?.retryLocalSummary(retryContext) },
                    feedbackMessage: presentation.feedbackMessage,
                    settling: originSessionId.map { ProviderFailureOrigin(sessionId: $0, turnId: turnId) },
                    feedbackOrigin: originSessionId.map { FeedbackOrigin(itemId: itemId, sessionId: $0, work: .summary) }
                )
            }
        }
    }

    func finishStreamingTurnIfReady(_ turnId: String) {
        guard completedStreamingTurnIds.contains(turnId),
              !streamingSpeechQueue.hasPendingSpeech(for: turnId),
              let engine else {
            return
        }
        do {
            snapshot = try engine.finishStreamingTurnPlayback(turnId: turnId)
            completedStreamingTurnIds.remove(turnId)
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            diagnostics["streamingTurnCompleted"] = turnId
            refreshSelectedItem()
        } catch {
            diagnostics["streamingTurnCompletionError"] = String(describing: error)
        }
    }

    private func syncPlaybackProgressBeforeGeneratedTurnDecision(engine: SessionEngine) -> Bool {
        let previousStatus = snapshot.status
        let previousTargetId = snapshot.targetId
        do {
            let updated = try engine.syncPlaybackProgress()
            if updated != snapshot {
                snapshot = updated
            }
            return previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
        } catch {
            diagnostics["playbackProgressSyncError"] = String(describing: error)
            return false
        }
    }

    /// The session and turn a provider call was started for. Without one, a failure settles
    /// the active session's last open job.
    struct ProviderFailureOrigin {
        var sessionId: String
        var turnId: String
    }

    func markProviderFailure(_ error: String, userMessage: String, itemId: String, retry: UserFeedbackEvent.Retry? = nil, feedbackMessage: String? = nil, settling origin: ProviderFailureOrigin? = nil, feedbackOrigin: FeedbackOrigin? = nil) {
        do {
            if let engine {
                snapshot = try engine.aiProviderFailed(error: error, sessionId: origin?.sessionId, turnId: origin?.turnId)
                refreshSelectedItem()
            }
        } catch {
            diagnostics["providerFailurePersistence"] = String(describing: error)
        }
        providerProbeStatus = userMessage
        diagnostics["providerProbe"] = providerProbeStatus
        reportFailure(userMessage, itemId: itemId, retry: retry, feedbackMessage: feedbackMessage, origin: feedbackOrigin)
    }
}
