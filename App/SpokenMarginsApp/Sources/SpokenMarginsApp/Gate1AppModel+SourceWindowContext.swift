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

/// A Margin's source-window context and its voice transcription (#966).
extension Gate1AppModel {
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
        let files: [HeardSourceWindowFiles.Segment]
        do { files = try heardSourceWindows.store(window, key: key) } catch {
            diagnostics[diagnosticKey] = "write_failed:\(error.localizedDescription)"
            return
        }
        let totalMs = files.reduce(0) { $0 + $1.durationMs }
        diagnostics[diagnosticKey] = "captured:\(totalMs)ms;segments=\(files.count);before=\(window.coversBeforeAnchor ? 1 : 0);after=\(window.coversAfterAnchor ? 1 : 0);end=\(window.endReason)"
        // #652: drop the files when the Margin is gone or its context is already ready, since nothing would use them.
        // If the Margins can't be read, keep them: a later schedule may still need them.
        guard !files.isEmpty, let store, let margins = try? store.loadInterjections(sessionId: window.request.sessionId) else { return }
        let interjection = margins.first(where: { $0.id == window.request.interjectionId })
        guard let interjection, HeardSourceWindowFiles.isStillNeeded(by: interjection) else {
            heardSourceWindows.discard(key)
            return
        }
        scheduleSourceWindowContextIfNeeded(for: interjection)
    }

    /// No heard audio yet: the tap delivers it about a minute after playback resumes. If it never arrives (the
    /// listener stopped, or the tap wasn't running), say so instead of leaving context pending forever.
    private func awaitHeardSourceWindow(for interjection: Interjection) {
        let key = Self.marginIdentity(interjection)
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "waiting:heard_audio"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(240))
            guard let self, self.heardSourceWindows.segments(for: key) == nil,
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

    private func transcribeHeardSourceWindow(for interjection: Interjection, itemId: String, reportsResult: Bool) {
        let key = Self.marginIdentity(interjection)
        guard !pendingSourceContextInterjectionIds.contains(key), let files = heardSourceWindows.take(key) else { return }
        pendingSourceContextInterjectionIds.insert(key)
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
                    try? SourceTranscriptionCaches.remove(.windows, itemId: scratchID, cachesDirectory: caches)
                }
            }
            HeardSourceWindowFiles.delete(files)
            await MainActor.run {
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
    func scheduleSourceWindowContextIfNeeded(for interjection: Interjection, reportsResult: Bool = false) -> Bool {
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
           let window = SourceAnchorContextResolver.sourceContextWindow(
               from: storedTimeline,
               anchorMediaTimeMs: anchorMediaTimeMs,
               windowBeforeMs: sourceWindowContextBeforeMs,
               windowAfterMs: sourceWindowContextAfterMs
           ) {
            run { engine in
                snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, sessionId: interjection.sessionId, timeline: window)
                heardSourceWindows.discard(Self.marginIdentity(interjection)) // #652: the context is ready without it
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
            if heardSourceWindows.segments(for: Self.marginIdentity(interjection)) != nil {
                transcribeHeardSourceWindow(for: interjection, itemId: item.id, reportsResult: reportsResult)
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
        // #871: at most two of these run at once, nearest the playhead first. A finished download used to start
        // one per Margin, all together.
        let identity = Self.marginIdentity(interjection)
        sourceWindowJobQueue.enqueue(id: identity, anchorMediaTimeMs: anchorMediaTimeMs, playhead: { [weak self, itemId = item.id] in
            // Asked each time the queue picks a job, so a seek while jobs wait is followed. A retry the listener
            // asked for goes first; otherwise the order follows the playhead of the episode that's playing.
            if reportsResult { return anchorMediaTimeMs }
            guard let self, self.snapshot.itemId == itemId else { return nil }
            return self.snapshot.currentMediaTimeMs
        }) { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs, windowBeforeMs = sourceWindowContextBeforeMs, windowAfterMs = sourceWindowContextAfterMs] in
            guard let self else { return }
            // Every way out clears the mark, so a failure inside `run` can't leave the Margin stuck as pending.
            defer { self.pendingSourceContextInterjectionIds.remove(identity) }
            let request = PostResumeAudioSampleRequest(
                interjectionId: interjectionId,
                sessionId: interjection.sessionId,
                itemId: itemId,
                anchorMediaTimeMs: anchorMediaTimeMs,
                targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
            )
            // It may have waited in line a while. A Margin deleted meanwhile (kept, with status "deleted") has nothing to recover.
            guard let stored = self.storedInterjection(request: request), stored.status != "deleted" else { return }
            do {
                let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                    url: transcriptionURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: windowBeforeMs,
                    windowAfterMs: windowAfterMs
                )
                let reference = await SourceWindowReferenceEvidence.generate(
                    from: analysis,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    outputDirectory: Result { try self.podcastAnchorEvidenceDirectory(for: request) },
                    idPrefix: self.podcastAnchorEvidenceID(request: request, suffix: "source-window")
                )
                self.run { engine in
                    self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, sessionId: interjection.sessionId, timeline: analysis.timeline)
                    self.heardSourceWindows.discard(identity) // #652: the context is ready without it
                    if !reference.evidence.isEmpty {
                        try self.persistPodcastAnchorEvidence(
                            request: request,
                            evidence: reference.evidence,
                            sourceExactEditionSHA256: nil
                        )
                    }
                    self.refreshSelectedItem()
                    self.refreshMarginRows()
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "complete:speech_window"
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = provenance
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowSignature", sessionId: interjection.sessionId, interjectionId: interjectionId)] = reference.evidence.isEmpty
                        ? "unavailable:\(reference.failure ?? "temporary_audio_unavailable")"
                        : "complete:\(reference.evidence.count)"
                    self.pendingSourceContextInterjectionIds.remove(identity)
                    if reportsResult { self.reportConfirmation("Source context recovered.") }
                }
            } catch {
                self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "failed:\(error.localizedDescription)"
                self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "unavailable"
                self.pendingSourceContextInterjectionIds.remove(identity)
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
        return true
    }

    func retrySourceWindowContexts(itemId: String) {
        guard let store else { return }
        let sessions = (try? store.loadSessions(itemId: itemId)) ?? []
        for session in sessions {
            let interjections = (try? store.loadInterjections(sessionId: session.id)) ?? []
            for interjection in interjections where interjection.targetType == .item
                && interjection.anchor.mediaTimeMs != nil
                && interjection.status != "deleted"
                && interjection.anchorContextStatus != .ready
                && !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) {
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
        }
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
        let audioEvidenceKey = Self.marginDiagnosticKey("interjectionAudioAtCapture", interjection)
        let supportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        Task.detached(priority: .utility) { [weak self] in
            let evidence = Self.interjectionAudioEvidence(for: audioPath, applicationSupportDirectory: supportDirectory)
            await MainActor.run { self?.diagnostics[audioEvidenceKey] = evidence }
        }
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
                        withdrawRetryOffer(Self.transcriptionRetryKey(interjection))
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
                        recordFailedRetry(of: interjection, failure: failure)
                        presentTranscriptionFailure(TranscriptionFailureWording.notice(error: failure, isRetry: true), for: interjection)
                    } else {
                        run { engine in
                            snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
                            refreshSelectedItem()
                        refreshMarginRows()
                            diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "failed:\(failure)"
                            diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                            presentTranscriptionFailure(TranscriptionFailureWording.notice(error: failure, isRetry: false), for: interjection)
                        }
                    }
                    retryingInterjectionTranscriptionIds.remove(Self.marginIdentity(interjection))
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            }
        }
    }
}
