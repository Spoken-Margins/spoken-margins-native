import Foundation
import SessionKit
import SessionKitPersistence

/// Summary, discussion and pasted response entry points. Moved out of `Gate1AppModel.swift` unchanged (#960).
extension Gate1AppModel {
    /// The AI jobs (and, for a failed summary, its notes) behind the Summarize / Retry controls. Those controls ask on
    /// every render of the playback screen, so this reads the store once per state of the session, off the main
    /// thread, and answers from the last read meanwhile (#2508). The key is the session's own snapshot fields, which
    /// the engine updates whenever a job or Margin changes.
    private var summaryRecords: SummaryRetryRecords? {
        summaryRecordsRequest.flatMap { summaryRecordsCache.current(key: $0.key, load: $0.load, onLoaded: $0.onLoaded) }
    }

    private var summaryRecordsRequest: (key: String, load: @Sendable () async -> SummaryRetryRecords?, onLoaded: @MainActor () -> Void)? {
        guard let sessionId = snapshot.sessionId, let itemId = snapshot.itemId, let store else { return nil }
        let s = snapshot
        let key = [s.sessionId, s.itemId, s.targetType, s.targetId, s.pendingAiJobKind, s.pendingAiJobStatus, s.turnStatus, s.lastFailure]
            .map { $0 ?? "" }.joined(separator: "|") + "|\(s.activeInterjectionCount)|\(s.pendingAiJobCount)"
        return (key, { try? await StoreReader(store).read { try SummaryRetryRecords.load(store: $0, sessionId: sessionId, itemId: itemId) } },
                { [weak self] in self?.objectWillChange.send() })
    }

    /// Returns once the Summarize controls answer for the session's current state, not the previous one (#2747).
    /// A tap waits on this before deciding; tests use it as their seam instead of sleeping.
    func settleSummaryRecords() async {
        while let request = summaryRecordsRequest, !summaryRecordsCache.isSettled(key: request.key) {
            _ = await summaryRecordsCache.settle(key: request.key, load: request.load, onLoaded: request.onLoaded)
        }
    }

    func summarize() {
        // Retry vs a new summary is decided from the jobs as they are now: the cache may still hold the answer from
        // before the last summary finished or failed, and acting on it would start the wrong one (#2747). With no
        // on-device model both ways end in the same message, so that answer stays immediate.
        if !remoteProviderExperienceEnabled, localFoundationModelAvailable,
           let key = summaryRecordsRequest?.key, !summaryRecordsCache.isSettled(key: key) {
            Task { [weak self] in
                guard let self else { return }
                await settleSummaryRecords()
                hangTelemetry.labels.scoped("summarizeAfterSettle") { summarize() }
            }
            return
        }
        if !remoteProviderExperienceEnabled {
            do {
                if let original = try recoverableLocalSummaryRetryContext() {
                    retryLocalSummary(original)
                    return
                }
            } catch {
                reportFailure(error, context: "Could not check the original summary", itemId: snapshot.itemId)
                return
            }
        }
        let itemId = snapshot.itemId ?? ""
        withdrawRetryOffer("summary")
        if !remoteProviderExperienceEnabled {
            guard localFoundationModelAvailable else {
                diagnostics["summaryPreflight"] = "local_model_unavailable"
                reportFailure(localFoundationModelAvailabilityDescription)
                return
            }
            guard pendingSourceContextInterjectionIds.isEmpty else {
                reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
                return
            }
            guard canSummarizeInterjections else {
                reportFailure("A Margin summary already exists for this session.")
                return
            }
            syncPlaybackProgressForLifecycle()
            run { engine in
                snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
                let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
                let contexts = localSummaryContexts(interjections: engine.lastSummaryCandidates)
                let retryContext = LocalSummaryRetryContext(
                    itemId: itemId, sessionId: snapshot.sessionId ?? "", turnId: turnId,
                    scope: summaryScopeForCurrentTarget(),
                    interjectionIds: engine.lastSummaryCandidates.map(\.id), contexts: contexts
                )
                submitLocalSummary(itemId: itemId, turnId: turnId, contexts: contexts, retryContext: retryContext)
                refreshSelectedItem()
                reportSuccess("On-device summary started.")
            }
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isAISetupNeededPresented = true
            diagnostics["summaryPreflight"] = "api_key_missing"
            return
        }
        guard pendingSourceContextInterjectionIds.isEmpty else {
            reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
            return
        }
        guard canSummarizeInterjections else {
            reportFailure("A Margin summary already exists for this session.")
            return
        }
        syncPlaybackProgressForLifecycle()
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
            let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
            submitProviderJobIfNeeded(kind: "interjection_summary", itemId: itemId, turnId: turnId, messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
            refreshSelectedItem()
            reportConfirmation(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
        }
    }

    /// A banner may outlive navigation or edits. Retry the recorded request, never
    /// recompute a summary from whichever target happens to be active now (#1469).
    func retryLocalSummary(_ original: LocalSummaryRetryContext) {
        withdrawRetryOffer("summary")
        guard snapshot.itemId == original.itemId,
              selectedItem.id == original.itemId,
              snapshot.sessionId == original.sessionId,
              summaryScopeForCurrentTarget() == original.scope else {
            reportFailure("Return to the original item and listening target to retry this summary.", itemId: original.itemId)
            return
        }
        guard localFoundationModelAvailable else {
            reportFailure(localFoundationModelAvailabilityDescription, itemId: original.itemId)
            return
        }
        guard let store, let engine else {
            reportFailure("The original summary is unavailable. Open the item and try again.", itemId: original.itemId)
            return
        }
        do {
            let jobs = try store.loadAIJobs(sessionId: original.sessionId)
            let turns = try store.loadTurns(sessionId: original.sessionId)
            let interjections = try store.loadInterjections(sessionId: original.sessionId)
            let sourceIds = Set(original.interjectionIds)
            // SQLite orders by last update. A harmless save must not reorder a retry.
            let byId = Dictionary(uniqueKeysWithValues: interjections.map { ($0.id, $0) })
            let source = original.interjectionIds.compactMap { byId[$0] }.filter { $0.status == "active" }
            guard let job = jobs.last(where: { $0.turnId == original.turnId && $0.kind == "interjection_summary" }),
                  job.itemId == original.itemId, job.status == "retryable",
                  let turn = turns.first(where: { $0.id == original.turnId }),
                  turn.status == "failed" || turn.status == "failed_partial",
                  Set(turn.sourceInterjectionIds) == sourceIds,
                  Set(source.map(\.id)) == sourceIds,
                  source.allSatisfy({ note in
                      original.scope.targetType == "turn"
                          ? note.targetType != .item && note.targetId == original.scope.turnId
                          : note.targetType == .item && note.targetId == original.itemId
                  }),
                  localSummaryContexts(interjections: source) == original.contexts else {
                reportFailure("The original summary or its Margins changed or are unavailable. Open the original item to start a new summary.", itemId: original.itemId)
                return
            }
            snapshot = try engine.retryAIJob(jobId: job.id)
            submitLocalSummary(itemId: original.itemId, turnId: original.turnId, contexts: original.contexts, retryContext: original)
            refreshSelectedItem()
            reportSuccess("On-device summary retry started.")
        } catch {
            // A store read failure is not evidence that the original notes disappeared.
            reportFailure(error, context: "Could not recover the original summary", itemId: original.itemId)
        }
    }

    /// The label and action use the same current-target recovery rule. An unrelated
    /// or unrecoverable old failure must not trap every new Summarize action in Retry.
    var canRetryLocalSummary: Bool {
        guard !remoteProviderExperienceEnabled, hasActiveSession else { return false }
        return (try? recoverableLocalSummaryRetryContext()) != nil
    }

    /// After relaunch only source identity is durable: use the current contents of
    /// those original notes, not newly added notes or another target's notes.
    private func recoverableLocalSummaryRetryContext() throws -> LocalSummaryRetryContext? {
        guard let sessionId = snapshot.sessionId, let itemId = snapshot.itemId, let records = summaryRecords else { return nil }
        let jobs = SummaryRetryRecords.retryableSummaryJobs(in: records.jobs, itemId: itemId)
        // This property is read during ordinary playback renders. Most sessions have no failed summary.
        guard !jobs.isEmpty else { return nil }
        let turns = records.turns
        let interjections = records.interjections
        let byId = Dictionary(uniqueKeysWithValues: interjections.map { ($0.id, $0) })
        var candidates: [LocalSummaryRetryContext] = []
        for job in jobs {
            guard let turn = turns.first(where: { $0.id == job.turnId }),
                  turn.status == "failed" || turn.status == "failed_partial",
                  !turn.sourceInterjectionIds.isEmpty else { continue }
            let source = turn.sourceInterjectionIds.compactMap { byId[$0] }.filter { $0.status == "active" }
            guard source.count == turn.sourceInterjectionIds.count,
                  let first = source.first,
                  source.allSatisfy({ $0.targetId == first.targetId && ($0.targetType == .item) == (first.targetType == .item) }),
                  first.targetType != .item || first.targetId == itemId else { continue }
            let scope = first.targetType == .item ? SummaryScope(targetType: "item") : SummaryScope(targetType: "turn", turnId: first.targetId)
            guard scope == summaryScopeForCurrentTarget() else { continue }
            candidates.append(LocalSummaryRetryContext(
                itemId: itemId, sessionId: sessionId, turnId: turn.id, scope: scope,
                interjectionIds: turn.sourceInterjectionIds, contexts: localSummaryContexts(interjections: source)
            ))
        }
        // The generic Retry control cannot identify one of several original jobs.
        return candidates.count == 1 ? candidates.first : nil
    }

    private func retryPendingLocalSummary() {
        do {
            guard let original = try recoverableLocalSummaryRetryContext() else {
                reportFailure("The original summary is unavailable for this target. Return to its target, or use Summarize to start a new summary.", itemId: snapshot.itemId)
                return
            }
            retryLocalSummary(original)
        } catch {
            reportFailure(error, context: "Could not recover the original summary", itemId: snapshot.itemId)
        }
    }

    func discuss(followUp: String) {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Discuss is disabled in this release. Copy your notes to another chatbot and paste its response back here instead.")
            return
        }
        guard pendingSourceContextInterjectionIds.isEmpty else {
            reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
            return
        }
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentInterjections = currentDiscussionInterjections()
        let request = Gate1DiscussionContext.primaryRequest(explicitFollowUp: trimmed, currentInterjections: currentInterjections)
        submitDiscussionFollowUp(request, explicitFollowUp: trimmed, primaryInterjections: currentInterjections)
    }

    func latestPendingJob(kind: String) -> AIJob? {
        summaryRecords.flatMap { SummaryRetryRecords.latestPending(in: $0.jobs, kind: kind) }
    }

    func followUp(_ text: String) {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Remote discussion is disabled in this release.")
            return
        }
        submitDiscussionFollowUp(text, explicitFollowUp: text, primaryInterjections: currentDiscussionInterjections())
    }

    private func submitDiscussionFollowUp(_ text: String, explicitFollowUp: String, primaryInterjections: [Interjection]) {
        guard run({ engine in snapshot = try engine.submitFollowup(text: text) }), let store, let sessionId = snapshot.sessionId else { return }
        Task {
            // The job the engine just saved is read off the main thread (#2508).
            let jobs = (try? await StoreReader(store).read { try $0.loadAIJobs(sessionId: sessionId) }) ?? []
            let turnId = SummaryRetryRecords.latestPending(in: jobs, kind: "assistant_response")?.turnId ?? "turn-response-001"
            submitProviderJobIfNeeded(
                kind: "assistant_response",
                itemId: snapshot.itemId ?? "",
                turnId: turnId,
                messages: [conversationPrompt(
                    followUp: text,
                    explicitFollowUp: explicitFollowUp,
                    primaryInterjections: primaryInterjections
                )]
            )
            refreshSelectedItem()
            reportConfirmation(snapshot.pendingAiJobStatus == "deferred" ? "Follow-up queued for later." : "Follow-up submitted.")
        }
    }

    func retryPendingAI() {
        guard remoteProviderExperienceEnabled else {
            retryPendingLocalSummary()
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isAISetupNeededPresented = true
            diagnostics["aiRetryPreflight"] = "api_key_missing"
            return
        }
        run { engine in
            guard let sessionId = snapshot.sessionId,
                  let job = try store?.loadAIJobs(sessionId: sessionId)
                    .last(where: { $0.status == "retryable" || $0.status == "pending" || $0.status == "deferred" }) else {
                reportFailure("No retryable AI job is available.")
                return
            }
            snapshot = try engine.retryAIJob(jobId: job.id)
            let turnId = job.turnId ?? (job.kind == "interjection_summary" ? "turn-summary-001" : "turn-response-001")
            let messages = job.messages.isEmpty ? [job.kind == "interjection_summary" ? summaryPrompt(interjections: engine.lastSummaryCandidates) : "Continue the discussion."] : job.messages
            submitProviderJobIfNeeded(kind: job.kind, itemId: snapshot.itemId ?? "", turnId: turnId, messages: messages, force: true)
            refreshSelectedItem()
            reportConfirmation("Retrying \(job.kind).")
        }
    }

    func importPastedAssistantResponse(autoPlay: Bool = true) {
        let text = pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            reportFailure("Paste a response before importing.")
            return
        }
        stopSpeechPreviews()
        run { engine in
            if !hasActiveSession {
                let started = try engine.startSession(itemId: activeItemId)
                snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
            }
            snapshot = try engine.importAssistantResponse(text: text, autoPlay: autoPlay)
            pastedAssistantResponse = ""
            refreshSelectedItem()
            screen = .playback
            reportSuccess(autoPlay ? "Imported and playing pasted response." : "Imported pasted response.")
        }
    }
}

/// Only in-memory request identity; no database or packet changes.
struct LocalSummaryRetryContext {
    let itemId: String
    let sessionId: String
    let turnId: String
    let scope: SummaryScope
    let interjectionIds: [String]
    let contexts: [String]
}
