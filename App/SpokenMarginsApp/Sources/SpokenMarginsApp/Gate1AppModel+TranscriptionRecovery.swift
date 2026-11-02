import SessionKit
import SessionKitPersistence

extension Gate1AppModel {
    /// No transcription of this run exists yet at launch, so a Margin still "pending" lost its worker with the
    /// last run: settle it so it offers Retry instead of promising work (#942). The scan and the writes run off the
    /// main thread (#2509). A Margin this run saved as pending (a new recording, a Watch import) is left
    /// alone, whenever it was made; the screen is read again after, when any were settled.
    func settleOrphanedTranscriptions(store: SQLiteSessionStore) {
        Task.detached(priority: .utility) { [weak self] in
            do {
                let settled = try store.settleOrphanedTranscriptions(skippingMarginsSavedThisRun: true)
                await self?.orphanedTranscriptionsSettled(settled)
            } catch {
                await self?.orphanedTranscriptionsSettled(failure: error)
            }
        }
    }

    private func orphanedTranscriptionsSettled(_ count: Int) {
        guard count > 0 else { return }
        diagnostics["orphanedTranscriptionsSettled"] = "\(count)"
        refreshSelectedItemInBackground()
        refreshMarginRowsInBackground()
    }

    private func orphanedTranscriptionsSettled(failure: Error) {
        diagnostics["orphanedTranscriptionsSettled"] = "failed:\(failure.localizedDescription)"
    }

    /// A manual Retry failed. A Margin never transcribed would stay "pending" with the retry over; one that has
    /// words keeps them and its status (#942).
    func recordFailedRetry(of interjection: Interjection, failure: String) {
        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "retry_failed:\(failure)"
        diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
        run { engine in
            snapshot = try engine.transcriptionRetryFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
            refreshSelectedItemInBackground()
            refreshMarginRow(sessionId: interjection.sessionId, interjectionId: interjection.id)
        }
    }

    /// Retry asks for a fresh transcription, so words the listener deleted may be replaced by it. Work that was
    /// already running when they deleted them is still dropped by the engine (#942).
    func scheduleRetriedTranscription(for interjection: Interjection) {
        engine?.transcriptionRequested(interjectionId: interjection.id, sessionId: interjection.sessionId)
        scheduleTranscription(for: interjection)
    }

    // MARK: Source transcript finishes (#2512)
    // The main-actor stretches that end a source-transcript import, labelled so a hang names them.

    func finishDiscoveredSourceTranscript(_ timeline: TranscriptTimeline, itemId: String, linkType: String) {
        hangTelemetry.labels.scoped("sourceTranscriptAttach") {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "attached:\(linkType)"
            attachSourceTranscriptTimeline(timeline, itemId: itemId)
        }
    }

    func markSourceTranscriptUnavailable(itemId: String, lastFailure: String) {
        hangTelemetry.labels.scoped("sourceTranscriptUnavailable") {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "unavailable:\(lastFailure)"
            diagnostics["sourceTranscriptionStatus"] = "unavailable"
            if activeItemId == itemId {
                sourceTranscriptStatus = "unavailable"
                snapshot.sourceTranscriptStatus = "unavailable"
            }
        }
    }

    func finishFullSourceTranscription(_ timeline: TranscriptTimeline, itemId: String) {
        hangTelemetry.labels.scoped("sourceTranscriptAttach") {
            importedPodcastPlacement.releaseFullSourceTranscription(itemId: itemId)
            attachSourceTranscriptTimeline(timeline, itemId: itemId)
        }
    }

    func failFullSourceTranscription(itemId: String, error: Error) {
        hangTelemetry.labels.scoped("sourceTranscriptionFailed") {
            importedPodcastPlacement.releaseFullSourceTranscription(itemId: itemId)
            diagnostics["sourceTranscriptionStatus"] = "unavailable"
            diagnostics["sourceTranscriptionError"] = String(describing: error)
            if activeItemId == itemId {
                sourceTranscriptStatus = "unavailable"
                snapshot.sourceTranscriptStatus = "unavailable"
            }
            if pendingMapGenerationItemId == itemId {
                pendingMapGenerationItemId = nil
            }
            if activeItemId == itemId, lastError == nil {
                statusMessage = "Audio ready. Source transcript and Listening Map are unavailable; notes will use timestamp context."
            }
        }
    }
}
