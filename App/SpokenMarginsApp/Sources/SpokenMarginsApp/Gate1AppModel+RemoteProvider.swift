import Foundation
import SessionKit
import SessionKitPersistence

/// AI provider jobs and local summary execution. Moved out of `Gate1AppModel.swift` unchanged (#960).
extension Gate1AppModel {
    func recoverInterruptedAIJobs(store: SQLiteSessionStore, rows: [LibraryItemRow]) throws {
        var recovered = 0
        for row in rows {
            for session in try store.loadSessions(itemId: row.id) {
                for var job in try store.loadAIJobs(sessionId: session.id) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = !remoteProviderExperienceEnabled
                        && job.providerType != "apple_foundation_on_device"
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

    func submitProviderJobIfNeeded(kind: String, itemId: String, turnId: String, messages: [String], force: Bool = false) {
        guard remoteProviderExperienceEnabled else {
            markProviderFailure("remote_provider_disabled", userMessage: "Remote AI is disabled in this release.", itemId: itemId)
            return
        }
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.", itemId: itemId)
            showSettingsTab()
            return
        }
        guard aiDataSharingConsent == .grantedV1 else {
            pendingProviderJobForConsent = PendingProviderJob(kind: kind, itemId: itemId, turnId: turnId, messages: messages, force: true)
            isAIDataSharingConsentPresented = true
            reportSuccess("Review how live AI uses this source before continuing.")
            return
        }
        let selectedModel = modelForAIJob(kind: kind)
        recordModelForPendingJob(kind: kind, model: selectedModel)
        statusMessage = "Streaming \(selectedModel) for \(kind)."
        lastError = nil
        Task {
            var receivedText = false
            var automaticAttempts = 0
            var streamsSpeechImmediately: Bool?
            while automaticAttempts < 2 {
                do {
                    var completed = false
                    let stream = openAIResponsesClient.stream(
                        credentials: .apiKey(providerAPIKey),
                        model: selectedModel,
                        instructions: systemPromptForAIJob(kind: kind),
                        messages: messages
                    )
                    for try await event in stream {
                        guard let engine else { return }
                        switch event {
                        case .started(let responseId):
                            diagnostics["lastOpenAIResponseId"] = responseId ?? "pending"
                            diagnostics["lastProviderTransport"] = "responses_sse"
                        case .textDelta(let delta):
                            receivedText = true
                            snapshot = try engine.aiStreamDelta(turnId: turnId, content: delta)
                            if streamsSpeechImmediately == nil {
                                streamsSpeechImmediately = !shouldDeferGeneratedTurnPlayback(turnId: turnId)
                            }
                            if streamsSpeechImmediately == true {
                                if snapshot.targetId != turnId {
                                    snapshot = try engine.activateStreamingTurn(turnId: turnId)
                                }
                                let stableUnits = snapshot.spokenUnits
                                streamingSpeechQueue.enqueue(stableUnits, turnId: turnId)
                                diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
                                diagnostics["streamingTurnId"] = turnId
                            }
                            refreshSelectedItem()
                        case .completed(let responseId):
                            diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
                            completed = true
                        }
                    }
                    guard completed else {
                        throw OpenAIResponsesError.api("OpenAI ended the stream before response.completed.")
                    }
                    guard let engine else { return }
                    snapshot = try engine.aiJobCompleted(turnId: turnId)
                    if streamsSpeechImmediately == true {
                        streamingSpeechQueue.enqueue(snapshot.spokenUnits, turnId: turnId)
                        completedStreamingTurnIds.insert(turnId)
                        diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
                        finishStreamingTurnIfReady(turnId)
                    } else {
                        let completedCurrentAudio = syncPlaybackProgressBeforeGeneratedTurnDecision(engine: engine)
                        try autoPlayCompletedTurn(
                            kind: kind,
                            turnId: turnId,
                            engine: engine,
                            completedCurrentAudio: completedCurrentAudio
                        )
                    }
                    refreshSelectedItem()
                    reportConfirmation(streamsSpeechImmediately == true
                        ? "Provider response saved and streamed to speech."
                        : "Provider response saved and queued after the current source.")
                    await generateAssistantChaptersIfUseful(turnId: turnId, model: selectedModel)
                    return
                } catch {
                    if !receivedText, automaticAttempts == 0 {
                        automaticAttempts += 1
                        diagnostics["providerAutomaticRetry"] = "before_first_delta"
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    markProviderFailure(String(describing: error), userMessage: receivedText ? "Provider stream stopped; the partial response was saved." : "Provider call failed.", itemId: itemId)
                    return
                }
            }
        }
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

    private func generateAssistantChaptersIfUseful(turnId: String, model: String) async {
        guard remoteProviderExperienceEnabled,
              let sessionId = snapshot.sessionId,
              let store,
              let turn = try? store.loadTurns(sessionId: sessionId).first(where: { $0.id == turnId }),
              let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 240 else {
            return
        }
        do {
            let messages = [ProviderPrompts.assistantChapters(responseText: text)]
            let response = try await openAIResponsesClient.complete(
                credentials: .apiKey(providerAPIKey),
                model: model,
                instructions: "Return only strict JSON for assistant response chapters. Do not use Markdown.",
                messages: messages
            )
            let chapters = try AssistantChapterParser.chapters(from: response, responseText: text)
            if let engine {
                snapshot = try engine.aiChaptersCompleted(turnId: turnId, chapters: chapters)
                refreshSelectedItem()
            }
            diagnostics["assistantChapters:\(turnId)"] = "complete:\(chapters.count)"
        } catch {
            diagnostics["assistantChapters:\(turnId)"] = "unavailable:\(error.localizedDescription)"
        }
    }

    func callProvider(messages: [String], model: String, systemPrompt: String) async throws -> String {
        guard remoteProviderExperienceEnabled else {
            throw ProviderCallError.remoteProviderDisabled
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCallError.missingAPIKey
        }
        guard aiDataSharingConsent == .grantedV1 else {
            throw ProviderCallError.dataSharingConsentRequired
        }
        diagnostics["lastProviderRequestURL"] = OpenAIResponsesClient.endpoint.absoluteString
        diagnostics["lastProviderRequestStartedAt"] = "\(Date().timeIntervalSince1970)"
        diagnostics["lastProviderTransport"] = "responses_stream"
        var responseText = ""
        var completed = false
        for try await event in openAIResponsesClient.stream(
            credentials: .apiKey(providerAPIKey),
            model: model,
            instructions: systemPrompt,
            messages: messages
        ) {
            switch event {
            case .started(let responseId):
                diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
            case .textDelta(let delta):
                responseText += delta
            case .completed(let responseId):
                diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
                completed = true
            }
        }
        guard completed else {
            throw OpenAIResponsesError.api("OpenAI ended the Listening Map stream before response.completed.")
        }
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIResponsesError.emptyResponse }
        return trimmed
    }

    func modelForAIJob(kind: String) -> String {
        Gate1ProviderRequestFactory.modelForAIJob(
            kind: kind,
            listeningMapModel: listeningMapModel,
            summaryModel: summaryModel,
            conversationModel: conversationModel,
            fallbackProviderModel: fallbackProviderModel()
        )
    }

    func fallbackProviderModel() -> String {
        let listeningMapFallback = listeningMapModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !listeningMapFallback.isEmpty {
            return listeningMapFallback
        }
        let storedFallback = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedFallback.isEmpty ? "gpt-5.6" : storedFallback
    }

    func systemPromptForAIJob(kind: String) -> String {
        Gate1ProviderRequestFactory.systemPromptForAIJob(kind: kind)
    }

    private func recordModelForPendingJob(kind: String, model: String) {
        guard let sessionId = snapshot.sessionId,
              let store,
              var job = try? store.loadAIJobs(sessionId: sessionId).last(where: { $0.kind == kind && $0.status != "complete" }) else {
            return
        }
        job.model = model
        try? store.updateAIJob(job)
        diagnostics["last\(kind.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: ""))Model"] = model
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

private enum ProviderCallError: Error, CustomStringConvertible {
    case missingAPIKey
    case dataSharingConsentRequired
    case remoteProviderDisabled

    var description: String {
        switch self {
        case .missingAPIKey:
            return "provider_api_key_missing"
        case .dataSharingConsentRequired:
            return "ai_data_sharing_consent_required"
        case .remoteProviderDisabled:
            return "remote_provider_disabled"
        }
    }
}
