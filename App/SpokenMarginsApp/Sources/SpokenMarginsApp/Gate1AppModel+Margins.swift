import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

struct PendingProviderJob {
    let kind: String
    let turnId: String
    let messages: [String]
    let force: Bool
}

typealias InterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> String
typealias AlignedInterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> AlignedInterjectionTranscript
typealias ShareMarginSilenceAnalysisHandler = @Sendable (
    _ sourceURL: URL,
    _ alignedTranscript: AlignedInterjectionTranscript
) throws -> [InterjectionCleanupDecision]
typealias ShareMarginAudioCleanupHandler = @Sendable (
    _ sourceURL: URL,
    _ destinationURL: URL,
    _ decisions: [InterjectionCleanupDecision]
) async throws -> Int

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct AssistantChapterEnvelope: Decodable {
    struct Candidate: Decodable {
        var id: String
        var title: String
        var anchor: String
    }

    var schemaVersion: String
    var chapters: [Candidate]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private enum ProviderCallError: Error, CustomStringConvertible {
    case http(Int, String)
    case emptyResponse
    case invalidURL
    case missingAPIKey
    case dataSharingConsentRequired
    case remoteProviderDisabled

    var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(240))"
        case .emptyResponse:
            return "empty_response"
        case .invalidURL:
            return "provider_url_invalid"
        case .missingAPIKey:
            return "provider_api_key_missing"
        case .dataSharingConsentRequired:
            return "ai_data_sharing_consent_required"
        case .remoteProviderDisabled:
            return "remote_provider_disabled"
        }
    }
}

extension Gate1AppModel {
    func refreshMarginRows() {
        do {
            let store = try requireStore()
            // Library rows refresh asynchronously on navigation. Retrieval must
            // use durable membership so freshly imported items are not omitted.
            let activeItems = Dictionary(uniqueKeysWithValues: try store.listItems()
                .filter { $0.deletedAt == nil }.map { ($0.id, $0.title) })
            let rows = try store.loadSessions().flatMap { session -> [MarginRow] in
                guard let itemTitle = activeItems[session.itemId] else { return [] }
                return try store.loadInterjections(sessionId: session.id)
                    .filter { $0.status == "active" }
                    .map {
                        MarginRow(
                            interjection: $0,
                            itemTitle: itemTitle,
                            sessionDate: session.updatedAt ?? session.createdAt
                        )
                    }
            }
            sharedMarginRows = try store.loadImportedCommentaryLayers()
                .filter { $0.deletedAt == nil && ($0.itemId == nil || activeItems[$0.itemId ?? ""] != nil) }
                .flatMap { layer in
                    try store.loadImportedCommentaryInterjections(layerId: layer.id).map {
                        SharedMarginRow(interjection: $0, layer: layer, itemTitle: activeItems[layer.itemId ?? ""] ?? layer.itemIdentity.title)
                    }
                }
                .sorted { $0.interjection.createdAt > $1.interjection.createdAt }
            marginRows = rows.sorted { lhs, rhs in
                let leftSessionDate = lhs.sessionDate ?? .distantPast
                let rightSessionDate = rhs.sessionDate ?? .distantPast
                if leftSessionDate != rightSessionDate { return leftSessionDate > rightSessionDate }
                if lhs.interjection.createdAt != rhs.interjection.createdAt {
                    return lhs.interjection.createdAt > rhs.interjection.createdAt
                }
                return lhs.id < rhs.id
            }
            marginNotesDelivery.deliverSoon() // A Margin or its transcript may be new (#171).
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    var marginScopeItems: [LibraryItemRow] {
        let ids = Set(marginRows.map { $0.interjection.itemId } + sharedMarginRows.compactMap { $0.layer.itemId } + [selectedItem.id])
        return libraryItems.filter { ids.contains($0.id) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var visiblePrivateMarginRows: [MarginRow] {
        marginRows.filter { row in
            let matchesFilter: Bool
            switch marginCollectionQuery.filter {
            case .all: matchesFilter = true
            case .starred: matchesFilter = row.interjection.isStarredForSharing == true
            case .attention: matchesFilter = row.needsAttention
            case .shared: matchesFilter = false
            }
            return matchesFilter && marginCollectionQuery.includes(itemID: row.interjection.itemId) && marginCollectionQuery.matches([row.fullText, row.itemTitle])
        }
    }

    var visibleSharedMarginRows: [SharedMarginRow] {
        guard marginCollectionQuery.filter == .shared else { return [] }
        return sharedMarginRows.filter {
            marginCollectionQuery.includes(itemID: $0.layer.itemId) && marginCollectionQuery.matches([$0.interjection.approvedTranscript, $0.itemTitle, $0.collectionLabel])
        }
    }

    func marginSourceContext(_ row: MarginRow) -> String? {
        // The saved bounded anchor belongs to this Margin's source or generated target.
        let parts = [row.interjection.anchor.anchorBefore, row.interjection.anchor.anchorAfter]
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " … ").prefix(600))
    }

    /// Opens the Margin a notes-folder link names (#171).
    func openMargin(_ link: MarginDeepLink) {
        bootstrapLibraryIfNeeded() // A cold launch from the link can arrive before the root view loads the Library.
        let matches = { (row: MarginRow) in row.interjection.sessionId == link.sessionId && row.interjection.id == link.marginId }
        if !marginRows.contains(where: matches) { refreshMarginRows() }
        guard let row = marginRows.first(where: matches) else { return reportFailure("This Margin is no longer in your Library.") }
        openMarginInTimeline(row)
    }

    func openMarginInTimeline(_ row: MarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margin_timeline") else { return }
        if let activeSessionID = snapshot.sessionId,
           activeSessionID != row.interjection.sessionId {
            reportWarning("This Margin belongs to another session. Now Playing was left unchanged.")
            diagnostics["marginTimelineNavigation"] = "blocked_active_session_replacement"
            return
        }
        do {
            let store = try requireStore()
            if snapshot.sessionId == nil {
                guard let session = try store.loadSession(id: row.interjection.sessionId) else {
                    throw SessionKitError.persistenceFailed("margin_session_missing")
                }
                openSession(session)
            }
            requestedTimelineFocusMarginID = row.id
            screen = .timeline
        } catch {
            reportFailure(error, context: "Open Margin failed")
        }
    }

    @discardableResult
    func playMarginMoment(_ row: MarginRow) -> Bool {
        guard !rejectNavigationOrSessionMutationWhileRecording("play_margin_moment") else { return false }
        let previousItemID = snapshot.itemId
        do {
            let store = try requireStore()
            guard let session = try store.loadSession(id: row.interjection.sessionId),
                  session.itemId == row.interjection.itemId,
                  let interjection = try store.loadInterjections(sessionId: session.id).first(where: {
                      $0.id == row.interjection.id && $0.sessionId == session.id
                          && $0.itemId == session.itemId && $0.status == "active"
                  }) else {
                throw SessionKitError.invalidCommandForState("This Margin's listening session is unavailable.")
            }
            let detail = try loadItemDetail(id: session.itemId, store: store)
            if engine == nil { installEngine(try makeEngine(store: store)) }
            guard let engine else { return false }
            // URL registration is separate from selection; the engine owns exact
            // target validation and the reversible playback transaction.
            try prepareSourceMediaPlayback(itemId: session.itemId)
            endMarginMoment()
            snapshot = try engine.playInterjectionAnchor(interjection)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            stopInterjectionAudioPlayback()
            activeItemId = session.itemId
            selectedItem = detail
            if previousItemID != session.itemId { resetMixWithOtherAudioForNewSession() }
            startMarginMomentIfSpoken(interjection, store: store)
            screen = .playback
            lastError = nil
            return true
        } catch {
            if let engine { snapshot = engine.snapshot }
            if let previousItemID { podcastDownloadCoordinator?.configureActiveItem(previousItemID) }
            reportFailure(error, context: "Could not play this Margin's position")
            return false
        }
    }

    /// Spoken podcast Margins get the full moment: lead-in, the Margin inline, then the item's other spoken
    /// Margins as playback reaches them. Written Margins and text items keep playing from the anchor.
    private func startMarginMomentIfSpoken(_ interjection: Interjection, store: SQLiteSessionStore) {
        guard Self.isInlineSpokenMargin(interjection), let anchorMs = interjection.anchor.mediaTimeMs else { return }
        let sessions: [Session] = (try? store.loadSessions(itemId: interjection.itemId)) ?? []
        let spoken: [Interjection] = sessions
            .flatMap { session -> [Interjection] in (try? store.loadInterjections(sessionId: session.id)) ?? [] }
            .filter(Self.isInlineSpokenMargin)
        var voiceURLs: [String: URL] = [:]
        for margin in spoken + [interjection] {
            if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }
        }
        startMarginMoment(
            itemId: interjection.itemId,
            target: MarginMomentAnchor(marginId: Self.marginIdentity(interjection), mediaTimeMs: anchorMs),
            otherMargins: spoken.map {
                MarginMomentAnchor(marginId: Self.marginIdentity($0), mediaTimeMs: $0.anchor.mediaTimeMs ?? 0)
            },
            voiceURLs: voiceURLs,
            title: "Your Margin",
            isApproximate: false
        )
    }

    /// Tapping a shared Margin in the Timeline plays its moment (#158): a lead-in, their voice, then the item.
    /// Position is the best the app has: a verified or interpolated match, else the sender's own time.
    func playSharedMarginMoment(_ row: SharedMarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("play_shared_margin_moment") else { return }
        guard let itemID = row.layer.itemId else {
            reportFailure("The source for this shared Margin isn't in your Library.")
            return
        }
        guard let position = SharedMarginPlaybackPosition(row.interjection) else {
            reportFailure("This shared Margin has no position in the episode.")
            return
        }
        guard let voiceURL = row.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) else {
            reportFailure("This shared Margin contains reviewed text but no playable voice recording.")
            return
        }
        endMarginMoment()
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID else { return }
        // The moment plays this voice; the automatic shared-Margin prompt mustn't play it again.
        announcedImportedInterjectionIDs.insert(row.interjection.id)
        let targetID = "shared::\(row.layer.id)::\(row.interjection.id)"
        startMarginMoment(
            itemId: itemID,
            target: MarginMomentAnchor(marginId: targetID, mediaTimeMs: position.mediaTimeMs),
            otherMargins: [],
            voiceURLs: [targetID: voiceURL],
            title: "\(row.collectionLabel)'s Margin",
            isApproximate: position.isApproximate
        )
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        screen = .playback
    }

    private func startMarginMoment(
        itemId: String,
        target: MarginMomentAnchor,
        otherMargins: [MarginMomentAnchor],
        voiceURLs: [String: URL],
        title: String,
        isApproximate: Bool
    ) {
        let sequence = MarginMomentSequence(itemId: itemId, target: target, otherMargins: otherMargins)
        let conductor = MarginMomentConductor(
            sequence: sequence,
            source: .init(
                pause: { [weak self] in self?.pause() },
                resume: { [weak self] in self?.resumePlayback() },
                seek: { [weak self] in self?.seekMedia(toMediaTimeMs: $0) }
            ),
            voiceURL: { voiceURLs[$0] }
        )
        conductor.voiceRate = Float(Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate))
        conductor.prepareAudioSession = {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
        }
        conductor.onVoiceUnavailable = { [weak self] (marginId: String, reason: String) in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            self?.reportWarning("That Margin's recording couldn't play, so listening continues.")
        }
        conductor.onChange = { [weak self, weak conductor] in
            guard let self, let conductor, self.marginMomentConductor === conductor else { return }
            self.marginMoment = conductor.sequence
            self.marginMomentVoiceIsPaused = conductor.isVoicePaused
            // Nothing left to play inline: the card goes away and the item simply continues.
            if conductor.sequence.phase == .listening, conductor.sequence.unplayed.isEmpty { self.endMarginMoment() }
        }
        marginMomentConductor = conductor
        marginMomentTitle = title
        marginMomentPositionIsApproximate = isApproximate
        conductor.start()
        diagnostics["marginMoment"] = "started:lead_in_ms=\(target.mediaTimeMs - sequence.startMediaTimeMs);others=\(sequence.unplayed.count - 1);approximate=\(isApproximate)"
    }

    private nonisolated static func isInlineSpokenMargin(_ margin: Interjection) -> Bool {
        guard margin.status == "active", margin.captureKind != .written, margin.targetType == .item else { return false }
        return margin.anchor.mediaTimeMs != nil && margin.audioPath != nil
    }

    /// "Play it now" on the coming-up cue.
    func playMarginMomentNow() {
        marginMomentConductor?.playTargetNow()
    }

    /// Stops the Margin that's playing and continues the item.
    func skipMarginMomentVoice() {
        marginMomentConductor?.skipVoice()
    }

    /// Stops playing Margins inline. The item keeps its current play state.
    func endMarginMoment() {
        marginMomentConductor?.cancel()
        marginMomentConductor = nil
        marginMoment = nil
        marginMomentVoiceIsPaused = false
    }

    func observeMarginMoment(_ current: SessionSnapshot) {
        guard let conductor = marginMomentConductor else { return }
        guard current.itemId == conductor.sequence.itemId else { return endMarginMoment() }
        conductor.observe(mediaTimeMs: current.currentMediaTimeMs)
    }

    func openMargins() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margins") else { return }
        openHome()
        requestedExperienceRoot = .margins
    }

    func beginInterjection() {
        guard !isFinishingInterjection, !isMarginCaptureCoolingDown else { return }
        guard playingImportedCommentary == nil else {
            reportWarning("Return to Source before recording a Margin.")
            return
        }
        guard marginMomentConductor?.isPlayingVoice != true else {
            reportWarning("Skip or finish the Margin that's playing before recording a new one.")
            return
        }
        guard snapshot.skimBridgeState == nil else {
            reportWarning("Margins are unavailable while a scene summary is playing. Pause or cancel Skim first.")
            return
        }
        guard !recordingNavigationIsLocked else { return }
        let voiceCaptureRequestID = UUID()
        pendingVoiceCaptureRequestID = voiceCaptureRequestID
        recordingPermissionDenied = false
        isRequestingRecordingPermission = true
        statusMessage = "Starting Margin..."
        lastError = nil
        diagnostics["lastInterjectionTap"] = "begin"
        let requestedAt = Date()
        recordingPresentationContext = RecordingPresentationContext(
            itemTitle: selectedItem.title.isEmpty ? "Current item" : selectedItem.title,
            locationTitle: snapshot.chapterTitle ?? "Current listening position",
            progressPercent: snapshot.currentPlaybackProgressPercent,
            startedAt: requestedAt
        )
        if recordingClientOverride != nil, microphonePermissionRequest == nil {
            startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
            return
        }
        #if canImport(AVFoundation) && os(iOS)
        let recordPermissionIsGranted = AVAudioApplication.shared.recordPermission == .granted
        if recordPermissionIsGranted, microphonePermissionRequest == nil {
            diagnostics["lastMicrophonePermissionResult"] = "granted"
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
            }
            return
        }
        #endif
        Task {
            let granted = await requestMicrophonePermission()
            guard pendingVoiceCaptureRequestID == voiceCaptureRequestID else { return }
            guard granted else {
                isRequestingRecordingPermission = false
                recordingPresentationContext = nil
                pendingVoiceCaptureRequestID = nil
                recordingPermissionDenied = true
                reportFailure("Microphone access is required to record Margins. Enable microphone access in Settings and try again.")
                return
            }
            startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
        }
    }

    private func startInterjectionRecording(requestedAt: Date, captureID: UUID) {
        guard pendingVoiceCaptureRequestID == captureID else { return }
        defer {
            isRequestingRecordingPermission = false
            pendingVoiceCaptureRequestID = nil
        }
        synchronizeStreamingSpeechAnchorIfNeeded()
        streamingSpeechQueue.pauseForInterjection()
        run { engine in
            snapshot = try engine.beginInterjection()
            if snapshot.isRecording {
                recordingPresentationContext = RecordingPresentationContext(
                    itemTitle: selectedItem.title,
                    locationTitle: snapshot.chapterTitle ?? "Current listening position",
                    progressPercent: snapshot.currentPlaybackProgressPercent,
                    startedAt: Date()
                )
                let latencyMs = max(0, Int(Date().timeIntervalSince(requestedAt) * 1000))
                diagnostics["lastInterjectionRecordingStartLatencyMs"] = "\(latencyMs)"
                reportSuccess("Recording Margin.")
            }
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
        }
    }

    /// #217: waits as long as the system prompt is up; a slow Allow is still a yes.
    private func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        if let microphonePermissionRequest { return await microphonePermissionRequest() }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await SystemRecordingClient.requestRecordPermission() },
            currentStatus: { Self.microphonePermissionStatus() },
            timeout: .seconds(timeoutSeconds)
        )
        diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied"
        return granted
    }

    private nonisolated static func microphonePermissionStatus() -> PermissionPromptStatus {
        #if canImport(AVFoundation) && os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #else
        return .granted
        #endif
    }

    /// Publish acknowledgement before synchronous recorder/store finalization.
    /// Keep capture gated briefly after dismissal so a second tap cannot start a new Margin.
    func requestFinishInterjection() {
        guard snapshot.isRecording, !isFinishingInterjection else { return }
        isFinishingInterjection = true
        isMarginCaptureCoolingDown = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.finishInterjection()
            self.isFinishingInterjection = false
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.isMarginCaptureCoolingDown = false
        }
    }

    func finishInterjection() {
        guard snapshot.isRecording else { return }
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            if let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            reportConfirmation("Margin saved. Transcription is continuing in the background.")
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
            refreshMarginRows()
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func recordSavedInterjectionForOnboarding() {
        markOnboardingSteps([.firstInterjection])
        if guidedOnboardingStage == .practiceInterjection {
            setGuidedOnboardingStage(.reviewTimeline)
        }
    }

    func cancelInterjection() {
        if isRequestingRecordingPermission && !snapshot.isRecording {
            pendingVoiceCaptureRequestID = nil
            isRequestingRecordingPermission = false
            recordingPresentationContext = nil
            return
        }
        run { engine in
            snapshot = try engine.cancelInterjection()
            refreshSelectedItem()
            reportSuccess("Cancelled Margin.")
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func beginWrittenMargin() {
        guard !recordingNavigationIsLocked else { return }
        guard snapshot.skimBridgeState == nil, playingImportedCommentary == nil else {
            reportFailure("Return to the source before writing a Margin.")
            return
        }
        do {
            let store = try requireStore()
            if engine == nil { installEngine(try makeEngine(store: store)) }
            guard let engine else { return }
            synchronizeStreamingSpeechAnchorIfNeeded()
            streamingSpeechQueue.pauseForInterjection()
            let capture = try engine.beginWrittenInterjection()
            lastError = nil
            recordingPermissionDenied = false
            snapshot = engine.snapshot
            writtenMarginDraft = WrittenMarginDraft(
                capture: capture,
                text: "",
                itemTitle: (try? store.loadItem(id: capture.itemId).title) ?? "Current item",
                targetDescription: capture.targetType == .item ? "Source" : (capture.targetType == .assistantTurn ? "Assistant response" : "Interjection summary"),
                progressPercent: capture.roughPercent
            )
            recordingPresentationContext = nil
        } catch {
            streamingSpeechQueue.resumeAfterInterjection()
            reportFailure(error, context: "Written Margin could not start")
        }
    }

    func updateWrittenMarginText(_ text: String) {
        guard writtenMarginDraft != nil else { return }
        writtenMarginDraft?.text = text
    }

    func switchPendingVoiceCaptureToWrittenMargin() {
        guard isRequestingRecordingPermission, !snapshot.isRecording else { return }
        isRequestingRecordingPermission = false
        pendingVoiceCaptureRequestID = nil
        recordingPresentationContext = nil
        beginWrittenMargin()
    }

    func saveWrittenMargin(text: String) {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.saveWrittenInterjection(captureId: draft.capture.id, text: text)
            writtenMarginDraft = nil
            if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
            refreshSelectedItem()
            refreshMarginRows()
            if draft.priorWasPlaying && snapshot.status == .paused {
                reportWarning("Margin saved. Playback is paused; tap Play to continue.")
            } else {
                reportConfirmation("Written Margin saved.")
            }
        } catch {
            writtenMarginDraft?.text = text
            reportFailure(error, context: "Written Margin could not be saved")
        }
    }

    func cancelWrittenMargin() {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.cancelWrittenInterjection(captureId: draft.capture.id)
            writtenMarginDraft = nil
            if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
            refreshSelectedItem()
        } catch {
            reportFailure(error, context: "Written Margin could not be cancelled")
        }
    }

    func summarize() {
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
                submitLocalSummary(turnId: turnId, contexts: contexts)
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
            submitProviderJobIfNeeded(kind: "interjection_summary", turnId: turnId, messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
            refreshSelectedItem()
            reportConfirmation(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
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

    private func latestPendingJob(kind: String) -> AIJob? {
        guard let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else {
            return nil
        }
        return jobs.last {
            $0.kind == kind && ($0.status == "pending" || $0.status == "deferred")
        }
    }

    func followUp(_ text: String) {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Remote discussion is disabled in this release.")
            return
        }
        submitDiscussionFollowUp(text, explicitFollowUp: text, primaryInterjections: currentDiscussionInterjections())
    }

    private func submitDiscussionFollowUp(_ text: String, explicitFollowUp: String, primaryInterjections: [Interjection]) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
            let turnId = latestPendingJob(kind: "assistant_response")?.turnId ?? "turn-response-001"
            submitProviderJobIfNeeded(
                kind: "assistant_response",
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
            summarize()
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
            submitProviderJobIfNeeded(kind: job.kind, turnId: turnId, messages: messages, force: true)
            refreshSelectedItem()
            reportConfirmation("Retrying \(job.kind).")
        }
    }

    static func marginIdentity(_ interjection: Interjection) -> String {
        "\(interjection.sessionId)::\(interjection.id)"
    }

    /// Margin IDs repeat per session, so per-Margin diagnostics carry a hashed session token.
    static func marginDiagnosticKey(_ name: String, sessionId: String, interjectionId: String) -> String {
        PodcastAnchorCaptureDiagnostics.marginKey(name, sessionId: sessionId, interjectionId: interjectionId)
    }

    static func marginDiagnosticKey(_ name: String, _ interjection: Interjection) -> String {
        marginDiagnosticKey(name, sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    static func marginDiagnosticKey(_ name: String, _ request: PostResumeAudioSampleRequest) -> String {
        marginDiagnosticKey(name, sessionId: request.sessionId, interjectionId: request.interjectionId)
    }

    func isPlayingInterjectionAudio(_ interjection: Interjection) -> Bool {
        playingInterjectionAudioId == interjection.id && playingInterjectionAudioSessionID == interjection.sessionId
    }

    func isRetryingInterjectionTranscription(_ interjection: Interjection) -> Bool {
        retryingInterjectionTranscriptionIds.contains(Self.marginIdentity(interjection))
    }

    func isRetryingAnchorContext(_ interjection: Interjection) -> Bool {
        pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection))
    }

    func retryAnchorContext(_ interjection: Interjection) {
        guard interjection.captureKind != .written else { return }
        guard !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return }
        if !scheduleSourceWindowContextIfNeeded(for: interjection, reportsResult: true) {
            reportWarning("Context needs a source timestamp and completed Margin transcription. Retry when transcription finishes.")
        }
    }

    func retryInterjectionTranscription(_ interjection: Interjection) {
        guard interjection.captureKind != .written, interjection.audioPath != nil else {
            reportFailure("The saved Margin audio is unavailable.")
            return
        }
        guard retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(interjection)).inserted else { return }
        scheduleTranscription(for: interjection)
        reportConfirmation("Retranscribing the saved Margin audio.")
    }

    func toggleInterjectionAudioPlayback(_ interjection: Interjection) {
        #if canImport(AVFoundation)
        guard interjection.captureKind != .written else { return }
        if isPlayingInterjectionAudio(interjection) {
            stopInterjectionAudioPlayback()
            reportConfirmation("Stopped playing your Margin.")
            return
        }
        guard let audioPath = interjection.audioPath,
              let url = resolvedInterjectionAudioURL(for: audioPath),
              FileManager.default.fileExists(atPath: url.path) else {
            reportFailure("This Margin's audio is unavailable.")
            return
        }
        if snapshot.status.isPlaybackActive {
            pause()
        }
        stopInterjectionAudioPlayback()
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            let rate = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            player.defaultRate = Float(rate)
            interjectionAudioPlayer = player
            playingInterjectionAudioId = interjection.id
            playingInterjectionAudioSessionID = interjection.sessionId
            playingInterjectionAudioRate = rate
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if item.status == .failed {
                        self?.stopInterjectionAudioPlayback()
                        self?.reportFailure("This Margin's audio couldn't be played.")
                        return
                    }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self?.stopInterjectionAudioPlayback()
                        return
                    }
                }
            }
            player.playImmediately(atRate: Float(rate))
            reportConfirmation("Playing your Margin.")
        } catch {
            stopInterjectionAudioPlayback()
            reportFailure(error, context: "Margin playback failed")
        }
        #else
        reportFailure("Margin playback is unavailable on this device.")
        #endif
    }

    func stopInterjectionAudioPlayback() {
        let hadImportedMargin = playingImportedCommentary != nil
        playingImportedCommentary = nil
        importedCommentaryIsPaused = false
        sourceShouldResumeAfterImportedCommentary = false
        if hadImportedMargin {
            importedMarginRemoteControls.end()
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
        }
        #if canImport(AVFoundation)
        interjectionAudioPlayer?.pause()
        interjectionAudioPlayer?.replaceCurrentItem(with: nil)
        interjectionAudioPlayer = nil
        interjectionAudioCompletionTask?.cancel()
        interjectionAudioCompletionTask = nil
        #endif
        playingInterjectionAudioId = nil
        playingInterjectionAudioSessionID = nil
        playingInterjectionAudioRate = 1
    }

    func listenToPendingImportedCommentary() {
        guard let prompt = pendingImportedCommentary else { return }
        listenToImportedCommentary(prompt)
    }

    func dismissPendingImportedCommentary() {
        guard pendingImportedCommentary != nil else { return }
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        let shouldResume = sourcePausedForImportedCommentaryPrompt
        sourcePausedForImportedCommentaryPrompt = false
        if shouldResume, snapshot.status == .paused {
            resumePlayback()
        }
    }

    func listenToImportedCommentary(layerID: String, interjectionID: String) {
        guard let layer = selectedItem.importedCommentaryLayers.first(where: { $0.id == layerID }),
              let records = selectedItem.importedCommentaryInterjections[layerID],
              let offset = records.firstIndex(where: { $0.id == interjectionID }) else { return }
        listenToImportedCommentary(ImportedCommentaryPrompt(
            layer: layer,
            interjection: records[offset],
            index: offset + 1,
            count: records.count
        ))
    }

    func returnToSourceFromImportedCommentary() {
        stopImportedCommentaryPlayback(resumeSource: true)
    }

    private func listenToImportedCommentary(_ prompt: ImportedCommentaryPrompt) {
        #if canImport(AVFoundation)
        guard let audioPath = prompt.interjection.audioPath,
              let audioURL = resolvedApplicationSupportAssetURL(for: audioPath) else {
            dismissPendingImportedCommentary()
            reportFailure("This shared Margin contains reviewed text but no playable voice recording.")
            return
        }
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        let shouldResumeSource = sourcePausedForImportedCommentaryPrompt
            || snapshot.status.isPlaybackActive
            || (playingImportedCommentary != nil && sourceShouldResumeAfterImportedCommentary)
        sourcePausedForImportedCommentaryPrompt = false
        if snapshot.status.isPlaybackActive { pause() }
        stopInterjectionAudioPlayback()
        sourceShouldResumeAfterImportedCommentary = shouldResumeSource
        do {
            #if os(iOS)
            let options: AVAudioSession.CategoryOptions = mixesWithOtherAudio
                ? (lowersBackgroundAudio ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]) : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: audioURL)
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.volume = mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1
            let rate = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            player.defaultRate = Float(rate)
            interjectionAudioPlayer = player
            playingInterjectionAudioRate = rate
            playingImportedCommentary = prompt
            importedCommentaryIsPaused = false
            pendingImportedCommentary = nil
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(false)
            gate2CompactControls.setNowPlayingEnabled(false)
            gate2CompactControls.endLiveActivities()
            if !mixesWithOtherAudio {
                importedMarginRemoteControls.install { [weak self] command in
                    guard let self, self.playingImportedCommentary != nil else { return }
                    self.dispatchGate2CompactCommand(command, origin: "imported_margin_remote")
                }
            }
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self?.stopImportedCommentaryPlayback(resumeSource: true)
                        return
                    }
                    self?.publishImportedCommentaryNowPlaying()
                }
            }
            player.playImmediately(atRate: Float(rate))
        } catch {
            stopImportedCommentaryPlayback(resumeSource: false)
            reportFailure(error, context: "Shared Margin playback failed")
        }
        #else
        reportFailure("Shared Margin playback is unavailable on this device.")
        #endif
    }

    func setImportedCommentaryPaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard playingImportedCommentary != nil, let player = interjectionAudioPlayer else { return }
        if paused {
            player.pause()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        } else {
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                player.playImmediately(atRate: Float(playingInterjectionAudioRate))
            } catch {
                reportFailure(error, context: "Shared Margin resume failed")
                return
            }
        }
        importedCommentaryIsPaused = paused
        publishImportedCommentaryNowPlaying()
        #endif
    }

    private func publishImportedCommentaryNowPlaying() {
        #if canImport(AVFoundation)
        guard !mixesWithOtherAudio, let prompt = playingImportedCommentary, let player = interjectionAudioPlayer else { return }
        importedMarginRemoteControls.publish(
            sender: prompt.senderLabel, elapsed: player.currentTime().seconds,
            duration: player.currentItem?.duration.seconds ?? .nan,
            rate: importedCommentaryIsPaused ? 0 : Double(player.rate)
        )
        #endif
    }

    func stopImportedCommentaryPlayback(resumeSource: Bool) {
        let shouldResume = resumeSource && sourceShouldResumeAfterImportedCommentary
        stopInterjectionAudioPlayback()
        playingImportedCommentary = nil
        sourceShouldResumeAfterImportedCommentary = false
        if shouldResume, snapshot.status == .paused { resumePlayback() }
    }

    func reconcileImportedCommentary(previous: SessionSnapshot, current: SessionSnapshot) {
        guard pendingImportedCommentary == nil,
              playingImportedCommentary == nil,
              current.itemId == selectedItem.id else { return }
        let prompts = importedCommentaryPrompts(includeAnnounced: false)
        let crossed = prompts.filter { prompt in
            if let anchor = prompt.interjection.resolution.localMediaTimeMs,
               previous.currentMediaTimeMs != nil, current.currentMediaTimeMs != nil {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentMediaTimeMs, after: current.currentMediaTimeMs
                )
            }
            if let anchor = prompt.interjection.resolution.localStartChar {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentTextStart, after: current.currentTextStart
                )
            }
            return false
        }.sorted {
            Self.importedCommentaryPosition($0.interjection)
                < Self.importedCommentaryPosition($1.interjection)
        }
        guard let prompt = crossed.first else { return }
        crossed.forEach { announcedImportedInterjectionIDs.insert($0.id) }
        guard prompt.layer.revealMode != .fresh else { return }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: current.status.isPlaybackActive)
    }

    func importedCommentaryPrompts(includeAnnounced: Bool) -> [ImportedCommentaryPrompt] {
        selectedItem.importedCommentaryLayers
            .filter { layer in
                Self.isImportedCommentaryLayerPlaybackEligible(
                    layer,
                    records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
                )
            }
            .flatMap { layer in
                let records = (selectedItem.importedCommentaryInterjections[layer.id] ?? [])
                    .filter { Self.isPlayableImportedCommentaryResolution($0.resolution) }
                    .sorted { lhs, rhs in
                        Self.importedCommentaryPosition(lhs) < Self.importedCommentaryPosition(rhs)
                    }
                return records.enumerated().compactMap { pair -> ImportedCommentaryPrompt? in
                    let (offset, record) = pair
                    guard includeAnnounced || !announcedImportedInterjectionIDs.contains(record.id) else {
                        return nil
                    }
                    return ImportedCommentaryPrompt(
                        layer: layer,
                        interjection: record,
                        index: offset + 1,
                        count: records.count
                    )
                }
            }
    }

    private func presentImportedCommentaryPrompt(
        _ prompt: ImportedCommentaryPrompt,
        sourceWasPlaying: Bool
    ) {
        sourcePausedForImportedCommentaryPrompt = sourceWasPlaying
        if sourceWasPlaying, snapshot.status.isPlaybackActive { pause() }
        if !prompt.layer.isMuted { playImportedCommentaryCue() }
        pendingImportedCommentary = prompt
        if prompt.layer.revealMode == .guided {
            importedCommentaryAutoPlayTask?.cancel()
            importedCommentaryAutoPlayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled,
                      self?.pendingImportedCommentary?.id == prompt.id else { return }
                self?.listenToPendingImportedCommentary()
            }
        }
    }

    func jumpToImportedCommentary(interjectionID: String) -> Bool {
        guard let prompt = importedCommentaryPrompts(includeAnnounced: true)
            .first(where: { $0.interjection.id == interjectionID }) else {
            reportFailure("The selected Shared Margin is no longer available.")
            return false
        }
        let sourceWasPlaying = snapshot.status.isPlaybackActive
        announcedImportedInterjectionIDs.insert(prompt.id)
        if sourceWasPlaying { pause() }
        if let mediaTimeMs = prompt.interjection.resolution.localMediaTimeMs {
            seekMedia(toMediaTimeMs: mediaTimeMs)
        } else if let charOffset = prompt.interjection.resolution.localStartChar {
            seekText(toCharOffset: charOffset)
        } else {
            reportFailure("The selected Shared Margin does not have a verified local position.")
            return false
        }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: sourceWasPlaying)
        screen = .playback
        diagnostics["lastSharedMarginNavigation"] = "opened:\(interjectionID)"
        return true
    }

    private nonisolated static func importedCommentaryPosition(
        _ interjection: ImportedCommentaryInterjection
    ) -> Int {
        interjection.resolution.localMediaTimeMs
            ?? interjection.resolution.localStartChar
            ?? .max
    }

    nonisolated static func isPlayableImportedCommentaryResolution(
        _ resolution: ImportedAnchorResolution
    ) -> Bool {
        guard !resolution.isAmbiguous else { return false }
        if resolution.localMediaTimeMs != nil {
            return isInlinePodcastResolution(resolution)
        }
        guard resolution.localStartChar != nil else { return false }
        switch resolution.evidenceClass {
        case .articleTextVerified, .exactEdition, .recipientConfirmed:
            return true
        case .transcriptVerified, .acousticVerified, .fused, .mapInterpolated,
             .timestampFallback, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    nonisolated static func marginPlaybackRate(itemPlaybackRate: Double) -> Double {
        guard itemPlaybackRate.isFinite else { return 1 }
        return max(0.25, min(3, itemPlaybackRate))
    }

    private func playImportedCommentaryCue() {
        #if canImport(AVFoundation)
        do {
            commentaryCuePlayer = try AVAudioPlayer(data: Self.doubleChimeWAVData())
            commentaryCuePlayer?.volume = 0.65
            commentaryCuePlayer?.play()
        } catch {
            diagnostics["importedCommentaryCue"] = "failed:\(error.localizedDescription)"
        }
        #endif
    }

    #if canImport(AVFoundation)
    private static func doubleChimeWAVData() -> Data {
        let sampleRate = 44_100
        let segments: [(frequency: Double, seconds: Double)] = [(880, 0.08), (0, 0.08), (1_175, 0.11)]
        var samples: [Int16] = []
        for segment in segments {
            let count = Int(Double(sampleRate) * segment.seconds)
            for index in 0..<count {
                guard segment.frequency > 0 else { samples.append(0); continue }
                let progress = Double(index) / Double(max(1, count - 1))
                let envelope = sin(.pi * progress)
                let value = sin(2 * .pi * segment.frequency * Double(index) / Double(sampleRate)) * envelope * 0.30
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        let payloadBytes = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF"); appendLE(UInt32(36 + payloadBytes)); appendASCII("WAVEfmt ")
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)); appendLE(UInt16(2)); appendLE(UInt16(16)); appendASCII("data")
        appendLE(UInt32(payloadBytes)); samples.forEach { appendLE($0) }
        return data
    }
    #endif

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

    func deleteTranscript(interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, sessionId: interjection.sessionId, representation: "transcript")
            refreshSelectedItem()
            reportSuccess("Deleted transcript.")
        }
        refreshMarginRows()
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
            reportSuccess("Deleted Margin.")
        }
        refreshMarginRows()
    }

    func setInterjectionStarredForSharing(_ interjectionID: String, sessionId: String? = nil, starred: Bool) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCuration:\(interjectionID)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin sharing star could not be saved")
        }
    }

    func setMarginStarred(_ row: MarginRow, starred: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("star_margin") else { return }
        do {
            let store = try requireStore()
            guard var interjection = try store.loadInterjections(sessionId: row.interjection.sessionId).first(where: {
                $0.id == row.interjection.id
                    && $0.sessionId == row.interjection.sessionId
                    && $0.itemId == row.interjection.itemId
            }) else {
                throw SessionKitError.persistenceFailed("margin_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshMarginRows()
            if snapshot.sessionId == row.interjection.sessionId { refreshSelectedItem() }
            diagnostics["marginCuration:\(row.id)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin star could not be saved")
        }
    }

    func setInterjectionPrivateSharingNote(_ interjectionID: String, sessionId: String? = nil, note: String) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            let bounded = String(note.prefix(Self.privateSharingNoteCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            interjection.privateSharingNote = bounded.isEmpty ? nil : bounded
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCurationNote:\(interjectionID)"] = bounded.isEmpty ? "empty" : "saved"
        } catch {
            reportFailure(error, context: "Private sharing note could not be saved")
        }
    }

    var canFinishInterjection: Bool {
        snapshot.isRecording
    }

    var canSummarizeInterjections: Bool {
        aiSummaryExperienceAvailable && hasActiveSession && !unsummarizedInterjectionsForCurrentTarget().isEmpty
    }

    var isSummarizingInterjections: Bool {
        latestPendingJob(kind: "interjection_summary") != nil
    }

    var canRetryLocalSummary: Bool {
        guard !remoteProviderExperienceEnabled,
              hasActiveSession,
              let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else { return false }
        return jobs.contains { $0.kind == "interjection_summary" && $0.status == "retryable" }
    }

    var summaryActionTitle: String {
        if isSummarizingInterjections { return "Summarizing" }
        return canRetryLocalSummary ? "Retry Summary" : "Summarize Notes"
    }

    var interjectionButtonTitle: String {
        "Interject"
    }

    private func summaryScopeForCurrentTarget() -> SummaryScope {
        switch currentPlaybackTargetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return SummaryScope(targetType: "turn", turnId: currentPlaybackTargetId)
        default:
            return SummaryScope(targetType: "item")
        }
    }

    private func latestPendingSummaryTurnId() -> String? {
        guard let sessionId = snapshot.sessionId,
              let turns = try? store?.loadTurns(sessionId: sessionId) else { return nil }
        return turns
            .filter { $0.turnType == "interjection_summary" && $0.status != "complete" }
            .last?.id
    }

    private func unsummarizedInterjectionsForCurrentTarget() -> [Interjection] {
        Gate1SummaryEligibility.unsummarizedInterjections(
            turns: selectedItem.turns,
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId
        )
    }

    func submitProviderJobIfNeeded(kind: String, turnId: String, messages: [String], force: Bool = false) {
        guard remoteProviderExperienceEnabled else {
            markProviderFailure("remote_provider_disabled", userMessage: "Remote AI is disabled in this release.")
            return
        }
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.")
            screen = .settings
            return
        }
        guard aiDataSharingConsent == .grantedV1 else {
            pendingProviderJobForConsent = PendingProviderJob(kind: kind, turnId: turnId, messages: messages, force: true)
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
                    markProviderFailure(String(describing: error), userMessage: receivedText ? "Provider stream stopped; the partial response was saved." : "Provider call failed.")
                    return
                }
            }
        }
    }

    private func submitLocalSummary(turnId: String, contexts: [String]) {
        statusMessage = "Summarizing Margins on device."
        lastError = nil
        Task {
            do {
                var partials: [String] = []
                for context in contexts {
                    partials.append(try await localFoundationModelClient.summarizeInterjections(context: context))
                }
                while partials.count > 1 {
                    var reduced: [String] = []
                    var start = 0
                    while start < partials.count {
                        let end = min(partials.count, start + 4)
                        let group = partials[start..<end]
                        let payload = group.enumerated().map { index, summary in
                            "PARTIAL \(index + 1):\n\(String(summary.prefix(1_200)))"
                        }.joined(separator: "\n\n")
                        reduced.append(try await localFoundationModelClient.summarizeInterjections(context: payload))
                        start = end
                    }
                    partials = reduced
                }
                guard let response = partials.first, !response.isEmpty else {
                    throw LocalFoundationModelError.emptyResponse
                }
                guard let engine else { return }
                snapshot = try engine.aiStreamDelta(turnId: turnId, content: response)
                snapshot = try engine.aiJobCompleted(turnId: turnId)
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
            } catch {
                diagnostics["lastSummaryMode"] = "apple_foundation_failed"
                diagnostics["lastLocalSummaryErrorType"] = String(reflecting: type(of: error))
                markProviderFailure(
                    String(describing: error),
                    userMessage: "On-device summary failed: \(error.localizedDescription) Tap Retry Summary to try the model again.",
                    retry: .init(key: "summary") { [weak self] in self?.summarize() }
                )
            }
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
            let messages = [assistantChapterPrompt(responseText: text)]
            let response = try await openAIResponsesClient.complete(
                credentials: .apiKey(providerAPIKey),
                model: model,
                instructions: "Return only strict JSON for assistant response chapters. Do not use Markdown.",
                messages: messages
            )
            let chapters = try assistantChapters(from: response, responseText: text)
            if let engine {
                snapshot = try engine.aiChaptersCompleted(turnId: turnId, chapters: chapters)
                refreshSelectedItem()
            }
            diagnostics["assistantChapters:\(turnId)"] = "complete:\(chapters.count)"
        } catch {
            diagnostics["assistantChapters:\(turnId)"] = "unavailable:\(error.localizedDescription)"
        }
    }

    private func assistantChapterPrompt(responseText: String) -> String {
        """
        Create 2 to 5 navigation chapters for the spoken response below. If it has fewer than two meaningful sections, return an empty chapters array.
        Return exactly {"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ch-1","title":"Short title","anchor":"exact phrase copied from RESPONSE"}]}.
        Every anchor must be an exact contiguous phrase from RESPONSE and identify the start of its section.
        RESPONSE:
        <<<
        \(responseText)
        >>>
        """
    }

    private func assistantChapters(from raw: String, responseText: String) throws -> [Chapter] {
        let data = Data(raw.utf8)
        let envelope = try JSONDecoder().decode(AssistantChapterEnvelope.self, from: data)
        guard envelope.schemaVersion == "assistant-response-map.v1" else {
            throw SessionKitError.persistenceFailed("assistant_chapter_schema")
        }
        var seen = Set<String>()
        return try envelope.chapters.map { candidate in
            guard !candidate.id.isEmpty,
                  !candidate.title.isEmpty,
                  seen.insert(candidate.id).inserted,
                  let range = responseText.range(of: candidate.anchor) else {
                throw SessionKitError.persistenceFailed("assistant_chapter_anchor")
            }
            let start = responseText.distance(from: responseText.startIndex, to: range.lowerBound)
            let end = responseText.distance(from: responseText.startIndex, to: range.upperBound)
            return Chapter(
                id: candidate.id,
                title: candidate.title,
                startChar: start,
                endChar: end,
                percent: responseText.isEmpty ? 0 : Int((Double(start) / Double(responseText.count) * 100).rounded())
            )
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

    private func performProviderDataRequest(_ request: URLRequest, timeoutSeconds: TimeInterval = 30) async throws -> (Data, URLResponse) {
        guard remoteProviderExperienceEnabled else {
            throw ProviderCallError.remoteProviderDisabled
        }
        var timedRequest = request
        timedRequest.timeoutInterval = timeoutSeconds
        diagnostics["lastProviderRequestURL"] = timedRequest.url?.absoluteString ?? "none"
        diagnostics["lastProviderRequestStartedAt"] = "\(Date().timeIntervalSince1970)"
        return try await Self.performProviderDataRequestOffMain(timedRequest, timeoutSeconds: timeoutSeconds)
    }

    private nonisolated static func performProviderDataRequestOffMain(
        _ request: URLRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, URLResponse) {
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func makeChatCompletionsRequest(messages: [String], model: String, systemPrompt: String) -> URLRequest? {
        Gate1ProviderRequestFactory.makeChatCompletionsRequest(
            baseURL: providerBaseURL,
            apiKey: providerAPIKey,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )
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

    private func decodeProviderText(_ data: Data) throws -> String {
        if let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
           let content = response.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if let raw = String(data: data, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw
        }
        throw ProviderCallError.emptyResponse
    }

    func listeningMapPrompt(sourceText: String) -> String {
        """
        Create a Listening Map for the item content below.
        The user will listen to this content through text-to-speech, so the map must support quick navigation and situational awareness.
        Return only strict JSON. Use schemaVersion "listening-map.v1".
        Required object shape:
        {
          "schemaVersion": "listening-map.v1",
          "overview": "one or two sentence overview",
          "chapters": [
            {
              "id": "ch-1",
              "title": "short navigation title",
              "description": "what this chapter covers",
              "anchor": "exact contiguous phrase copied from ITEM CONTENT"
            }
          ]
        }
        Requirements: brief overview, navigable chapters, exact contiguous anchors copied from source, no invented anchors, no percent estimates, no start/end character offsets.
        JSON syntax rules: use ASCII double quotes for object keys and string delimiters. Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        Anchor quality rules: every anchor must be at least five words when possible; copy ordinary prose from the source, not headings; do not paraphrase; do not use ellipses.
        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    func listeningMapRepairPrompt(sourceText: String, invalidResponse: String, error: String) -> String {
        """
        Repair the Listening Map JSON below. Return only strict JSON with schemaVersion "listening-map.v1".

        Parser/validator error:
        \(error)

        Requirements:
        - Keep only JSON. No Markdown fences.
        - Use ASCII double quotes for JSON object keys and string delimiters.
        - Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        - Every chapter must have id, title, description, and anchor.
        - Every anchor must be an exact contiguous phrase copied from ITEM CONTENT, preferably at least five words.
        - Do not include percent estimates.
        - Prefer preserving the previous chapter intent if the anchor can be fixed.

        INVALID RESPONSE:
        <<<
        \(invalidResponse)
        >>>

        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    func latestInterjectionNeedingTranscription() -> Interjection? {
        guard let sessionId = snapshot.sessionId,
              let interjections = try? store?.loadInterjections(sessionId: sessionId) else { return nil }
        return interjections.last { $0.transcriptionStatus == "pending" && $0.audioPath != nil }
    }

    /// The tap hands over what was heard around a Margin: write it to temporary files, then transcribe if the
    /// Margin's own note transcription has finished (otherwise that completion schedules this).
    func handleHeardSourceWindow(_ window: HeardAudioWindow) {
        let key = HeardAudioWindowRecorder.key(window.request)
        let diagnosticKey = Self.marginDiagnosticKey("heardSourceWindow", sessionId: window.request.sessionId, interjectionId: window.request.interjectionId)
        do {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = caches.appending(path: "HeardSourceWindows/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [(url: URL, startMediaTimeMs: Int, durationMs: Int)] = []
            for (index, segment) in window.segments.enumerated() where window.durationMs(of: segment) >= 2_000 {
                let url = directory.appending(path: "segment-\(index).caf")
                try Self.writeHeardSegment(segment.samples, sampleRate: window.sampleRate, to: url)
                files.append((url, segment.startMediaTimeMs, window.durationMs(of: segment)))
            }
            let totalMs = files.reduce(0) { $0 + $1.durationMs }
            diagnostics[diagnosticKey] = "captured:\(totalMs)ms;segments=\(files.count);before=\(window.coversBeforeAnchor ? 1 : 0);after=\(window.coversAfterAnchor ? 1 : 0);end=\(window.endReason)"
            guard !files.isEmpty else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            heardSourceWindows[key] = files
        } catch {
            diagnostics[diagnosticKey] = "write_failed:\(error.localizedDescription)"
            return
        }
        guard let store,
              let interjection = try? store.loadInterjections(sessionId: window.request.sessionId)
                .first(where: { $0.id == window.request.interjectionId }) else { return }
        if interjection.anchorContextStatus != .ready {
            scheduleSourceWindowContextIfNeeded(for: interjection)
        }
    }

    private nonisolated static func writeHeardSegment(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SessionKitError.persistenceFailed("heard_audio_buffer_unavailable")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// No heard audio yet: the tap delivers it about a minute after playback resumes. If it never arrives (the
    /// listener stopped, or the tap wasn't running), say so instead of leaving context pending forever.
    private func awaitHeardSourceWindow(for interjection: Interjection) {
        let key = Self.marginIdentity(interjection)
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "waiting:heard_audio"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(240))
            guard let self, self.heardSourceWindows[key] == nil,
                  !self.pendingSourceContextInterjectionIds.contains(key),
                  let store = self.store,
                  let current = try? store.loadInterjections(sessionId: interjection.sessionId).first(where: { $0.id == interjection.id }),
                  current.anchorContextStatus != .ready else { return }
            self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "failed:heard_audio_unavailable"
            self.run { engine in
                self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjection.id, sessionId: interjection.sessionId)
                self.refreshMarginRows()
            }
        }
    }

    private func transcribeHeardSourceWindow(
        _ files: [(url: URL, startMediaTimeMs: Int, durationMs: Int)],
        for interjection: Interjection,
        itemId: String,
        reportsResult: Bool
    ) {
        let key = Self.marginIdentity(interjection)
        guard pendingSourceContextInterjectionIds.insert(key).inserted else { return }
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "scheduled:heard_audio"
        diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = "heard_stream_audio"
        if reportsResult { reportConfirmation("Recovering source context…") }
        run { engine in
            snapshot = try engine.sourceWindowContextPending(interjectionId: interjection.id, sessionId: interjection.sessionId)
        }
        Task { [weak self] in
            guard let self else { return }
            var parts: [(startMediaTimeMs: Int, timeline: MediaTimeline)] = []
            var failure: String?
            for file in files {
                // A unique folder per segment: the transcriber reuses an existing export in the same folder.
                let scratchID = "heard-\(UUID().uuidString)"
                do {
                    let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                        url: file.url, itemId: scratchID, anchorMediaTimeMs: 0, durationMs: file.durationMs,
                        windowBeforeMs: 0, windowAfterMs: file.durationMs
                    )
                    parts.append((file.startMediaTimeMs, analysis.timeline))
                } catch {
                    failure = error.localizedDescription
                }
                if let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    try? FileManager.default.removeItem(at: caches.appending(path: "SourceAudioTranscriptionWindows/\(scratchID)"))
                }
            }
            if let directory = files.first?.url.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: directory)
            }
            await MainActor.run {
                self.heardSourceWindows[key] = nil
                self.pendingSourceContextInterjectionIds.remove(key)
                let timeline = HeardAudioWindow.episodeTimeline(parts)
                let transcriptionKey = Self.marginDiagnosticKey("sourceWindowTranscription", interjection)
                self.run { engine in
                    if timeline.segments.isEmpty {
                        self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjection.id, sessionId: interjection.sessionId)
                        self.diagnostics[transcriptionKey] = "failed:heard_audio:\(failure ?? "no_speech")"
                        if reportsResult { self.reportWarning("Source context could not be recovered from the audio you heard.") }
                    } else {
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, sessionId: interjection.sessionId, timeline: timeline)
                        self.diagnostics[transcriptionKey] = "complete:heard_audio:\(timeline.segments.count)_segments"
                        if reportsResult { self.reportConfirmation("Source context recovered.") }
                    }
                    self.refreshSelectedItem()
                    self.refreshMarginRows()
                }
            }
        }
    }

    @discardableResult
    private func scheduleSourceWindowContextIfNeeded(for interjection: Interjection, reportsResult: Bool = false) -> Bool {
        guard interjection.captureKind != .written,
              interjection.targetType == .item,
              let anchorMediaTimeMs = interjection.anchor.mediaTimeMs,
              let store,
              let item = try? store.loadItem(id: interjection.itemId),
              let sourceURLString = item.media?.url,
              let canonicalSourceURL = URL(string: sourceURLString) else {
            return false
        }
        // Acoustic evidence can fail before note transcription even starts. That
        // fallback must not race the note for the speech-recognition service.
        let saved = try? store.loadInterjections(sessionId: interjection.sessionId)
            .first(where: { $0.id == interjection.id })
        guard saved?.transcriptionStatus != "pending",
              !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return false }
        switch item.media?.sourceType {
        case .some(.nativeMediaFile), .some(.remoteStream):
            break
        default:
            return false
        }
        if let storedTimeline = try? store.loadTranscriptTimeline(itemId: item.id)?.timeline,
           let window = Self.sourceContextWindow(
               from: storedTimeline,
               anchorMediaTimeMs: anchorMediaTimeMs,
               windowBeforeMs: sourceWindowContextBeforeMs,
               windowAfterMs: sourceWindowContextAfterMs
           ) {
            run { engine in
                snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, sessionId: interjection.sessionId, timeline: window)
                refreshSelectedItem()
                refreshMarginRows()
                if reportsResult { reportConfirmation("Source context recovered.") }
                diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "complete:stored_transcript"
                diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = "stored_transcript"
            }
            return true
        }
        let transcriptionURL = (item.media?.sourceType == .nativeMediaFile ? resolvedOwnedAudiobookURL(for: item) : nil)
            ?? importedPodcastRecipientLocalURLs[item.id]
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalSourceURL
        if !transcriptionURL.isFileURL {
            // #156: a window can't be cut from a stream after the fact (AVFoundation stops the export). Use the
            // minute before and after the Margin that the player's tap kept, once it has been handed over.
            if let heard = heardSourceWindows[Self.marginIdentity(interjection)] {
                transcribeHeardSourceWindow(heard, for: interjection, itemId: item.id, reportsResult: reportsResult)
            } else if reportsResult {
                // A manual retry comes long after the heard audio was used or dropped.
                reportWarning("Context for a streamed episode comes from the audio around the Margin as you heard it, and that's no longer available. Download the episode to recover it.")
            } else {
                awaitHeardSourceWindow(for: interjection)
            }
            return true
        }
        if reportsResult { reportConfirmation("Recovering source context…") }
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "scheduled"
        let provenance = transcriptionURL.isFileURL ? "downloaded_local_audio" : "bounded_remote_window"
        diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = provenance
        pendingSourceContextInterjectionIds.insert(Self.marginIdentity(interjection))
        run { engine in
            snapshot = try engine.sourceWindowContextPending(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
        }
        Task { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs, windowBeforeMs = sourceWindowContextBeforeMs, windowAfterMs = sourceWindowContextAfterMs] in
            guard let self else { return }
            do {
                let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                    url: transcriptionURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: windowBeforeMs,
                    windowAfterMs: windowAfterMs
                )
                var referenceEvidence: [CapturedPodcastAnchorEvidence] = []
                var referenceEvidenceFailure: String?
                if let localAudioURL = analysis.localAudioURL {
                    do {
                        let request = PostResumeAudioSampleRequest(
                            interjectionId: interjectionId,
                            sessionId: interjection.sessionId,
                            itemId: itemId,
                            anchorMediaTimeMs: anchorMediaTimeMs,
                            targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                        )
                        let outputDirectory = try self.podcastAnchorEvidenceDirectory(for: request)
                        let localAnchorMs = max(0, anchorMediaTimeMs - analysis.sourceStartMs)
                        let generated = try await PodcastAnchorEvidenceGenerator.generate(
                            sourceURL: localAudioURL,
                            anchorMediaTimeMs: localAnchorMs,
                            outputDirectory: outputDirectory,
                            idPrefix: self.podcastAnchorEvidenceID(request: request, suffix: "source-window")
                        )
                        referenceEvidence = generated.map { generated in
                            CapturedPodcastAnchorEvidence(
                                id: generated.id,
                                localPath: generated.fileURL.path,
                                durationMs: generated.durationMs,
                                anchorOffsetMs: generated.anchorOffsetMs,
                                provenance: analysis.provenance == .downloadedSourceReference
                                    ? .downloadedSourceReference
                                    : .sourceWindowReference,
                                windowRole: generated.id.hasSuffix("-pre")
                                    ? .sourceWindowBefore
                                    : .sourceWindowAfter
                            )
                        }
                    } catch {
                        referenceEvidenceFailure = error.localizedDescription
                    }
                    try? FileManager.default.removeItem(at: localAudioURL.deletingLastPathComponent())
                }
                await MainActor.run {
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, sessionId: interjection.sessionId, timeline: analysis.timeline)
                        if !referenceEvidence.isEmpty {
                            try self.persistPodcastAnchorEvidence(
                                request: PostResumeAudioSampleRequest(
                                    interjectionId: interjectionId,
                                    sessionId: interjection.sessionId,
                                    itemId: itemId,
                                    anchorMediaTimeMs: anchorMediaTimeMs,
                                    targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                                ),
                                evidence: referenceEvidence,
                                sourceExactEditionSHA256: nil
                            )
                        }
                        self.refreshSelectedItem()
                        self.refreshMarginRows()
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "complete:speech_window"
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = provenance
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowSignature", sessionId: interjection.sessionId, interjectionId: interjectionId)] = referenceEvidence.isEmpty
                            ? "unavailable:\(referenceEvidenceFailure ?? "temporary_audio_unavailable")"
                            : "complete:\(referenceEvidence.count)"
                        self.pendingSourceContextInterjectionIds.remove(Self.marginIdentity(interjection))
                        if reportsResult { self.reportConfirmation("Source context recovered.") }
                    }
                }
            } catch {
                await MainActor.run {
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "failed:\(error.localizedDescription)"
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "unavailable"
                    self.pendingSourceContextInterjectionIds.remove(Self.marginIdentity(interjection))
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjectionId, sessionId: interjection.sessionId)
                        self.refreshSelectedItem()
                        self.refreshMarginRows()
                    }
                    if reportsResult {
                        self.reportWarning("Source context could not be recovered: \(error.localizedDescription)")
                    }
                    // Source-window context is redundant, best-effort evidence.
                    // The Margin and its timestamp are already durable, and the
                    // Timeline exposes the retry state. Do not turn this expected
                    // degradation into a global error banner after every Margin.
                }
            }
        }
        return true
    }

    func retrySourceWindowContexts(itemId: String) {
        guard let store else { return }
        let sessions = (try? store.loadSessions(itemId: itemId)) ?? []
        for session in sessions {
            let interjections = (try? store.loadInterjections(sessionId: session.id)) ?? []
            for interjection in interjections where interjection.targetType == .item
                && interjection.anchor.mediaTimeMs != nil
                && interjection.anchorContextStatus != .ready
                && !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) {
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
        }
    }

    static func sourceContextWindow(
        from timeline: TranscriptTimeline,
        anchorMediaTimeMs: Int,
        windowBeforeMs: Int = 90_000,
        windowAfterMs: Int = 120_000
    ) -> TranscriptTimeline? {
        let startMs = max(0, anchorMediaTimeMs - windowBeforeMs)
        let endMs = min(timeline.durationMs ?? Int.max, anchorMediaTimeMs + windowAfterMs)
        let segments = timeline.segments.filter { segment in
            segment.endMs >= startMs && segment.startMs <= endMs
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: timeline.chapters.filter { $0.startMs >= startMs && $0.startMs <= endMs },
            durationMs: timeline.durationMs
        )
    }

    func scheduleTranscription(for interjection: Interjection) {
        guard let audioPath = interjection.audioPath else { return }
        recordAnchorCaptureDiagnostics(for: interjection)
        switch interjection.podcastAnchorEvidenceCaptureStatus {
        case .pendingPostResumeSample:
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "sampling:decoded_playback_post_resume"
        case .pendingExactLocalCapture:
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "sampling:exact_local_playback_edition"
        case .ready:
            break
        case .unavailable, nil:
            schedulePodcastAnchorEvidenceCapture(for: interjection)
        }
        diagnostics[Self.marginDiagnosticKey("interjectionAudioAtCapture", interjection)] = interjectionAudioEvidence(for: audioPath)
        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "scheduled"
        Task {
            do {
                let alignedTranscript = try await alignedInterjectionTranscriptionHandler?(audioPath)
                let transcript: String
                if let alignedTranscript {
                    transcript = alignedTranscript.text
                } else {
                    transcript = try await interjectionTranscriptionHandler(audioPath)
                }
                await MainActor.run {
                    run { engine in
                        if let alignedTranscript {
                            snapshot = try engine.transcriptionCompleted(
                                interjectionId: interjection.id,
                                sessionId: interjection.sessionId,
                                alignedTranscript: alignedTranscript
                            )
                        } else {
                            snapshot = try engine.transcriptionCompleted(
                                interjectionId: interjection.id,
                                sessionId: interjection.sessionId,
                                transcript: transcript
                            )
                        }
                        refreshSelectedItem()
                        refreshMarginRows()
                        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "complete"
                        reportSuccess("Transcribed Margin.")
                    }
                    retryingInterjectionTranscriptionIds.remove(Self.marginIdentity(interjection))
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            } catch {
                await MainActor.run {
                    let failure = String(describing: error)
                    let wasRetry = retryingInterjectionTranscriptionIds.contains(Self.marginIdentity(interjection))
                    if wasRetry {
                        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "retry_failed:\(failure)"
                        diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                        TranscriptionFailureWording.notice(error: failure, isRetry: true).present(warning: { reportWarning($0) }, failure: { reportFailure($0) })
                    } else {
                        run { engine in
                            snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
                            refreshSelectedItem()
                        refreshMarginRows()
                            diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "failed:\(failure)"
                            diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                            TranscriptionFailureWording.notice(error: failure, isRetry: false).present(warning: { reportWarning($0) }, failure: { reportFailure($0) })
                        }
                    }
                    retryingInterjectionTranscriptionIds.remove(Self.marginIdentity(interjection))
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            }
        }
    }

    private func schedulePodcastAnchorEvidenceCapture(for interjection: Interjection) {
        guard interjection.targetType == .item,
              let mediaTimeMs = interjection.anchor.mediaTimeMs,
              let sourceURL = podcastDownloadCoordinator?.validatedLocalURL(for: interjection.itemId),
              mediaPlaybackClient?.isUsingPlaybackURL(sourceURL, itemId: interjection.itemId) == true else {
            markPodcastAnchorEvidenceUnavailable(
                request: PostResumeAudioSampleRequest(
                    interjectionId: interjection.id,
                    sessionId: interjection.sessionId,
                    itemId: interjection.itemId,
                    anchorMediaTimeMs: interjection.anchor.mediaTimeMs ?? 0,
                    targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                ),
                reason: "no_exact_local_playback_edition"
            )
            return
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "scheduled"
        let request = PostResumeAudioSampleRequest(
            interjectionId: interjection.id,
            sessionId: interjection.sessionId,
            itemId: interjection.itemId,
            anchorMediaTimeMs: mediaTimeMs,
            targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
        )
        guard let root = try? podcastAnchorEvidenceDirectory(for: request) else {
            markPodcastAnchorEvidenceUnavailable(request: request, reason: "storage_unavailable")
            return
        }
        markPodcastAnchorEvidencePendingLocal(request: request)
        let evidenceIDPrefix = podcastAnchorEvidenceID(request: request, suffix: "local")
        Task.detached { [weak self] in
            do {
                let digestBeforeCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                let generated = try await PodcastAnchorEvidenceGenerator.generate(
                    sourceURL: sourceURL,
                    anchorMediaTimeMs: mediaTimeMs,
                    outputDirectory: root,
                    idPrefix: evidenceIDPrefix
                )
                let digestAfterCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                guard digestBeforeCapture == digestAfterCapture else {
                    throw SessionKitError.persistenceFailed("podcast_anchor_source_changed_during_capture")
                }
                let captured = generated.map {
                    CapturedPodcastAnchorEvidence(
                        id: $0.id,
                        localPath: $0.fileURL.path,
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: .exactLocalPlaybackEdition,
                        windowRole: $0.id.hasSuffix("-pre") ? .preInterjection : .postResume
                    )
                }
                await MainActor.run {
                    do {
                        try self?.persistPodcastAnchorEvidence(
                            request: request,
                            evidence: captured,
                            sourceExactEditionSHA256: digestAfterCapture
                        )
                        self?.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "complete:\(captured.count)"
                    } catch {
                        self?.markPodcastAnchorEvidenceUnavailable(
                            request: request,
                            reason: "local_signature_persistence_failed:\(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.markPodcastAnchorEvidenceUnavailable(
                        request: request,
                        reason: "local_signature_failed:\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    #if canImport(AVFoundation) && canImport(ShazamKit)
    func handlePostResumePodcastEvidence(_ result: PostResumePodcastEvidenceCaptureResult) {
        switch result {
        case .captured(let capture):
            do {
                let root = try podcastAnchorEvidenceDirectory(for: capture.request)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let evidenceID = podcastAnchorEvidenceID(
                    request: capture.request,
                    suffix: capture.windowRole == .preInterjection ? "stream-pre" : "stream-post"
                )
                let fileURL = root.appending(path: "\(evidenceID).shazamsignature")
                try capture.signatureData.write(to: fileURL, options: .atomic)
                try persistPodcastAnchorEvidence(
                    request: capture.request,
                    evidence: [CapturedPodcastAnchorEvidence(
                        id: evidenceID,
                        localPath: fileURL.path,
                        durationMs: capture.durationMs,
                        anchorOffsetMs: capture.anchorOffsetMs,
                        provenance: .observedDecodedPlayback,
                        windowRole: capture.windowRole == .preInterjection ? .preInterjection : .postResume
                    )],
                    sourceExactEditionSHA256: nil
                )
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", capture.request)] =
                    "complete:decoded_playback_\(capture.windowRole.rawValue):bytes=\(capture.signatureData.count)"
            } catch {
                markPodcastAnchorEvidenceUnavailable(
                    request: capture.request,
                    reason: "stream_signature_persistence_failed:\(error.localizedDescription)"
                )
            }
        case .landmark(let landmark):
            do {
                try persistSparseEpisodeFingerprintLandmark(landmark)
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "captured:\(landmark.trigger.rawValue):epoch=\(landmark.continuityEpoch)"
            } catch {
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "persistence_failed:\(error.localizedDescription)"
            }
        case .failed(let request, let reason):
            if let interjection = recordPodcastAnchorEvidenceFailureReason(request: request, reason: "stream_failed:\(reason)") {
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "stream_failed:\(reason)"
                schedulePodcastAnchorEvidenceCapture(for: interjection)
            } else {
                markPodcastAnchorEvidenceUnavailable(request: request, reason: reason)
            }
        }
    }
    #endif

    #if canImport(AVFoundation) && canImport(ShazamKit)
    private func persistSparseEpisodeFingerprintLandmark(
        _ capture: CapturedEpisodeFingerprintLandmark
    ) throws {
        guard let store else { throw SessionKitError.persistenceFailed("store_unavailable") }
        let safeItem = safePodcastEvidenceComponent(capture.itemId)
        let root = try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safeItem, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suffix = capture.gridIndex.map { "grid-\($0)" }
            ?? "epoch-\(capture.continuityEpoch)-\(capture.sourceMediaStartMs)"
        let assetID = "episode-signature-\(safeItem)-\(suffix)"
        let fileURL = root.appending(path: "\(assetID).shazamsignature")
        try capture.signatureData.write(to: fileURL, options: .atomic)

        let existing = try store.loadEditionFingerprintSpine(itemId: capture.itemId)
        var landmarks = existing?.landmarks.filter { $0.signatureAssetId != assetID } ?? []
        landmarks.append(EpisodeFingerprintLandmark(
            id: "landmark-\(suffix)",
            order: landmarks.count,
            sourceMediaStartMs: capture.sourceMediaStartMs,
            sourceMediaEndMs: capture.sourceMediaEndMs,
            anchorMediaTimeMs: capture.anchorMediaTimeMs,
            continuityEpoch: capture.continuityEpoch,
            trigger: capture.trigger,
            provenance: .observedDecodedPlayback,
            signatureAssetId: assetID
        ))
        landmarks = landmarks.sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }.enumerated().map { index, value in
            EpisodeFingerprintLandmark(
                id: value.id,
                order: index,
                sourceMediaStartMs: value.sourceMediaStartMs,
                sourceMediaEndMs: value.sourceMediaEndMs,
                anchorMediaTimeMs: value.anchorMediaTimeMs,
                continuityEpoch: value.continuityEpoch,
                trigger: value.trigger,
                provenance: value.provenance,
                signatureAssetId: value.signatureAssetId,
                transcriptSketchWindowId: value.transcriptSketchWindowId,
                generatorVersion: value.generatorVersion
            )
        }
        let item = try? store.loadItem(id: capture.itemId)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: existing?.id ?? "episode-spine-\(safeItem)",
            itemId: capture.itemId,
            canonicalURL: item?.externalReference ?? item?.media?.url,
            producingEditionDurationMs: item?.media?.durationMs,
            producingEditionSHA256: existing?.producingEditionSHA256,
            createdAt: existing?.createdAt ?? Date(),
            landmarks: landmarks
        ))
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: assetID,
            itemId: capture.itemId,
            category: .fingerprintMap,
            relativePath: "SpokenMargins/EpisodeMaps/\(safeItem)/\(assetID).shazamsignature",
            byteCount: Int64(capture.signatureData.count),
            isReproducible: false
        ))
    }
    #endif

    private func podcastAnchorEvidenceDirectory(for request: PostResumeAudioSampleRequest) throws -> URL {
        try applicationSupportDirectory()
            .appending(path: "SpokenMargins/AnchorEvidence", directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(request.sessionId), directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(request.interjectionId), directoryHint: .isDirectory)
    }

    private func podcastAnchorEvidenceID(
        request: PostResumeAudioSampleRequest,
        suffix: String
    ) -> String {
        "anchor-\(safePodcastEvidenceComponent(request.sessionId))-\(safePodcastEvidenceComponent(request.interjectionId))-\(suffix)"
    }

    func safePodcastEvidenceComponent(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return safe.isEmpty ? "unknown" : String(safe.prefix(96))
    }

    private func storedInterjection(request: PostResumeAudioSampleRequest) -> Interjection? {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId) else { return nil }
        return records.first { $0.id == request.interjectionId && $0.itemId == request.itemId }
    }

    private func persistPodcastAnchorEvidence(
        request: PostResumeAudioSampleRequest,
        evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?
    ) throws {
        guard let store,
              var interjection = try store.loadInterjections(sessionId: request.sessionId)
                .first(where: { $0.id == request.interjectionId && $0.itemId == request.itemId }) else {
            throw SessionKitError.persistenceFailed("podcast_anchor_interjection_missing")
        }
        var merged = interjection.podcastAnchorEvidence ?? []
        for newEvidence in evidence {
            merged.removeAll {
                $0.id == newEvidence.id
                    || ($0.windowRole == newEvidence.windowRole && $0.provenance == newEvidence.provenance)
            }
            merged.append(newEvidence)
        }
        interjection.podcastAnchorEvidence = merged.sorted { $0.id < $1.id }
        interjection.sourceExactEditionSHA256 = sourceExactEditionSHA256
        interjection.podcastAnchorEvidenceCaptureStatus = .ready
        if interjection.anchorContextStatus == .pending {
            interjection.anchorContextStatus = .unavailable
        }
        try store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    private func markPodcastAnchorEvidenceUnavailable(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              var interjection = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else {
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "unavailable:\(reason)"
            return
        }
        interjection.podcastAnchorEvidenceCaptureStatus = .unavailable
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
        try? store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] =
            "unavailable:\(interjection.podcastAnchorEvidenceFailureReason ?? reason)"
        scheduleSourceWindowContextIfNeeded(for: interjection)
    }

    private func markPodcastAnchorEvidencePendingLocal(request: PostResumeAudioSampleRequest) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              var interjection = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else { return }
        interjection.podcastAnchorEvidenceCaptureStatus = .pendingExactLocalCapture
        try? store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    /// Stores a failure without changing capture status, so a fallback that runs next can't hide it.
    private func recordPodcastAnchorEvidenceFailureReason(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) -> Interjection? {
        guard var interjection = storedInterjection(request: request) else { return nil }
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
        try? store?.saveInterjection(interjection)
        return interjection
    }

    private func interjectionAudioEvidence(for path: String) -> String {
        guard let url = resolvedInterjectionAudioURL(for: path) else {
            return "duration_ms=unknown;bytes=unknown"
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        #if canImport(AVFoundation)
        if let audioFile = try? AVAudioFile(forReading: url), audioFile.processingFormat.sampleRate > 0 {
            let durationMs = Int((Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1000).rounded())
            return "duration_ms=\(durationMs);bytes=\(bytes)"
        }
        #endif
        return "duration_ms=unknown;bytes=\(bytes)"
    }

    func resolvedInterjectionAudioURL(for path: String) -> URL? {
        Self.resolvedInterjectionAudioURL(
            for: path,
            applicationSupportDirectory: try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        )
    }

    /// Stored Margin audio paths may be absolute paths from an earlier app container
    /// (container UUIDs change on reinstall, restore, and some updates). Rebase them onto
    /// the current Application Support directory instead of failing.
    nonisolated static func resolvedInterjectionAudioURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        if path.hasPrefix("interjections/"), let applicationSupportDirectory {
            let legacyURL = applicationSupportDirectory.appending(path: "SpokenMargins").appending(path: path)
            if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        }
        return resolvedApplicationSupportAssetURL(
            for: path, applicationSupportDirectory: applicationSupportDirectory
        )
    }

    func resolvedApplicationSupportAssetURL(for path: String) -> URL? {
        Self.resolvedApplicationSupportAssetURL(
            for: path,
            applicationSupportDirectory: try? applicationSupportDirectory()
        )
    }

    nonisolated static func resolvedApplicationSupportAssetURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path)
        if directURL.isFileURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        guard let applicationSupportDirectory else { return nil }
        let supportMarker = "/Library/Application Support/"
        if let markerRange = path.range(of: supportMarker) {
            let relativePath = String(path[markerRange.upperBound...])
            let relocatedURL = applicationSupportDirectory.appending(path: relativePath)
            if fileManager.fileExists(atPath: relocatedURL.path) {
                return relocatedURL
            }
        }
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let relativeURL = applicationSupportDirectory.appending(path: relativePath)
        return fileManager.fileExists(atPath: relativeURL.path) ? relativeURL : nil
    }

    private func recordAnchorCaptureDiagnostics(for interjection: Interjection) {
        diagnostics[Self.marginDiagnosticKey("interjectionAnchorAtCapture", interjection)] = [
            "type=\(interjection.anchor.anchorType.rawValue)",
            "media_time=\(interjection.anchor.mediaTimeMs == nil ? "missing" : "present")",
            "segment=\(interjection.anchor.transcriptSegmentId == nil ? "missing" : "present")",
            "before=\(interjection.anchor.anchorBefore.isEmpty ? "missing" : "present")",
            "after=\(interjection.anchor.anchorAfter.isEmpty ? "missing" : "present")",
            "context=\(interjection.anchorContextStatus?.rawValue ?? "legacy")"
        ].joined(separator: ";")
    }

    private func summaryPrompt(interjections: [Interjection]) -> String {
        """
        I would like to have a session with you, the article, and my interjections below.
        \(sessionContextJSON(interjections: interjections, currentFollowUp: nil))
        """
    }

    private func localSummaryContexts(interjections: [Interjection]) -> [String] {
        let records: [[String: String]] = interjections.map { interjection in
            [
                "id": interjection.id,
                "anchorBefore": LocalInterjectionSummaryPolicy.boundedAnchorBefore(interjection.anchor.anchorBefore),
                "anchorAfter": LocalInterjectionSummaryPolicy.boundedAnchorAfter(interjection.anchor.anchorAfter),
                "note": String(LocalInterjectionSummaryPolicy.cleanSpokenNote(
                    interjection.cleanedTranscript ?? interjection.transcript ?? interjection.displayText ?? ""
                ).prefix(2_000))
            ]
        }
        var batches: [[[String: String]]] = []
        var current: [[String: String]] = []
        for record in records {
            let candidate = current + [record]
            if !current.isEmpty, encodedLocalSummaryContext(candidate).count > 6_500 {
                batches.append(current)
                current = [record]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches.map(encodedLocalSummaryContext)
    }

    private func encodedLocalSummaryContext(_ records: [[String: String]]) -> String {
        let payload: [String: Any] = [
            "schemaVersion": "local-interjection-summary.v1",
            "itemTitle": selectedItem.title,
            "interjections": records
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return records.enumerated().map { index, record in
                "\(index + 1). \(record["note"] ?? "")"
            }.joined(separator: "\n")
        }
        return json
    }

    private func conversationPrompt(followUp: String, explicitFollowUp: String, primaryInterjections: [Interjection]) -> String {
        let scopedInterjections = primaryInterjections.isEmpty ? currentDiscussionInterjections() : primaryInterjections
        return Gate1ProviderRequestFactory.conversationPrompt(
            followUp: followUp,
            contextJSON: sessionContextJSON(
                interjections: scopedInterjections,
                currentFollowUp: followUp,
                explicitFollowUp: explicitFollowUp,
                primaryInterjections: scopedInterjections
            )
        )
    }

    private func sessionContextJSON(
        interjections: [Interjection],
        currentFollowUp: String?,
        explicitFollowUp: String? = nil,
        primaryInterjections: [Interjection] = []
    ) -> String {
        let map: [String: Any] = [
            "schemaVersion": currentFollowUp == nil ? "session-export.v1" : "conversation-context.v2",
            "item": [
                "title": selectedItem.title,
                "text": selectedItem.text
            ],
            "listeningMap": [
                "overview": selectedItem.overview,
                "chapters": selectedItem.chapters.map { chapter in
                    [
                        "title": chapter.title,
                        "startChar": chapter.startChar,
                        "endChar": chapter.endChar
                    ]
                }
            ],
            "interjections": interjections.map { interjection in
                [
                    "targetType": interjection.targetType.rawValue,
                    "anchorBefore": interjection.anchor.anchorBefore,
                    "anchorAfter": interjection.anchor.anchorAfter,
                    "transcriptionStatus": interjection.transcriptionStatus,
                    "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                ]
            },
            "primaryUserIntent": currentFollowUp.map { followUp in
                [
                    "source": Gate1DiscussionContext.primaryIntentSource(
                        explicitFollowUp: explicitFollowUp ?? "",
                        currentInterjections: primaryInterjections
                    ),
                    "request": followUp,
                    "targetType": currentPlaybackTargetType,
                    "target": currentDiscussionTargetContext(),
                    "interjections": primaryInterjections.map { interjection in
                        [
                            "targetType": interjection.targetType.rawValue,
                            "anchorBefore": interjection.anchor.anchorBefore,
                            "anchorAfter": interjection.anchor.anchorAfter,
                            "transcriptionStatus": interjection.transcriptionStatus,
                            "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                        ]
                    }
                ] as [String: Any]
            } ?? NSNull(),
            "recentTurns": selectedItem.turns.suffix(6).map { turn in
                [
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "text": turn.summary ?? turn.text ?? turn.rawText ?? ""
                ]
            },
            "currentFollowUp": currentFollowUp.map { $0 as Any } ?? NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func currentDiscussionInterjections() -> [Interjection] {
        Gate1DiscussionContext.currentTargetInterjections(
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId,
            itemId: selectedItem.id
        )
    }

    private func currentDiscussionTargetContext() -> [String: Any] {
        let targetType = currentPlaybackTargetType
        let targetId = currentPlaybackTargetId ?? ""
        switch targetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            if let turn = selectedItem.turns.first(where: { $0.id == targetId }) {
                return [
                    "targetType": targetType,
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "summary": turn.summary ?? "",
                    "text": turn.text ?? turn.rawText ?? ""
                ]
            }
        default:
            break
        }
        return [
            "targetType": TargetType.itemTextTTS.rawValue,
            "title": selectedItem.title,
            "overview": selectedItem.overview
        ]
    }

    func turnTitleText(_ turn: ConversationTurn) -> String {
        switch turn.turnType {
        case "interjection_summary":
            return "summary"
        case "assistant_response":
            return "AI response"
        default:
            return "turn"
        }
    }
}
