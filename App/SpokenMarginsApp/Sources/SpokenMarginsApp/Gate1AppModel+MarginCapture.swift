import Foundation
import SessionKit
import Security
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

/// Whether a spoken Margin is really being recorded, and what happens when it is not (#937).
///
/// `MarginCaptureWatcher` polls the recorder and `MarginCaptureSupervisor` decides. This extension
/// connects them to the model: the recording screen reads `recordingCaptureHealth` and says
/// "Recording" only while audio is arriving.
extension Gate1AppModel {
    func startCaptureWatch() {
        recordingCaptureHealth = .starting
        captureWatcher.start(
            reading: { [weak self] in self?.engine?.recordingCaptureReading() },
            restart: { [weak self] in try self?.engine?.restartRecordingCapture() },
            changed: { [weak self] health, restarts in self?.captureHealthChanged(health, restarts: restarts) }
        )
    }

    func endCaptureWatch() {
        captureWatcher.stop()
        recordingCaptureHealth = .capturing
        gate2CompactControls.setMicrophone(.capturing)
    }

    private func captureHealthChanged(_ health: MarginCaptureSupervisor.Health, restarts: Int) {
        let wasCapturing = recordingCaptureHealth == .capturing
        recordingCaptureHealth = health
        gate2CompactControls.setMicrophone(health.liveActivityMicrophone)
        var fields = engine?.recordingCaptureDiagnostics() ?? [:]
        fields["health"] = health.diagnosticName
        fields["restarts"] = String(restarts)
        recordDeveloperDiagnostic("margin.capture.health", fields)
        diagnostics["lastVoiceCapture"] = Self.captureSummary(fields)
        switch health {
        case .capturing where !wasCapturing:
            reportSuccess("Recording Margin.")
        case .notCapturing:
            reportFailure(captureWatcher.hasKeepableAudio
                ? Self.keptAudioMessage
                : "The microphone isn't recording, so nothing is being saved. Tap Try again, or cancel and write the Margin instead.")
        default:
            break
        }
        // The health may be unchanged while only the keepable state flipped: redraw for Try again.
        objectWillChange.send()
    }

    /// The listener tapped Try again on a recording screen that says the microphone isn't recording.
    func retryMicrophone() {
        guard snapshot.isRecording else { return }
        if captureWatcher.retry() {
            lastError = nil
        } else {
            // Speech arrived since the last poll: a restart would delete it. Redraw without Try again.
            if case .notCapturing = captureWatcher.health, lastError != Self.keptAudioMessage {
                reportFailure(Self.keptAudioMessage)
            }
            objectWillChange.send()
        }
    }

    private static let keptAudioMessage = "The microphone stopped partway. What you said before is kept if you tap Save."

    /// Try again restarts the recorder and deletes what it holds, so it is not offered once the
    /// recording holds audio worth saving. `retryMicrophone()` checks the recorder again itself.
    var canRetryMicrophone: Bool { snapshot.isRecording && captureWatcher.canRetry }

    /// The recording stopped partway but holds speech: Save keeps it.
    var recordingHasKeepableAudio: Bool { snapshot.isRecording && captureWatcher.hasKeepableAudio }

    /// What saving the recording would keep. An empty recording is discarded here, not saved: nil means it was.
    func verdictForSavingRecording() -> MarginCaptureSupervisor.SaveVerdict? {
        let verdict = captureWatcher.saveVerdict()
        recordFinalCaptureDiagnostics(verdict.rawValue)
        guard verdict == .discardEmpty else { return verdict }
        discardEmptyRecording()
        return nil
    }

    /// Finish from the Lock Screen, a Live Activity or a widget goes around `finishInterjection()`, so it
    /// asks here first. Nil means the recording was empty and is gone: Finish must not save it. Cancel from
    /// there is logged. Every other command passes.
    func verdictForCompactCommand(_ command: CompactControlCommand) -> MarginCaptureSupervisor.SaveVerdict? {
        if command == .cancelInterjection { recordFinalCaptureDiagnostics("cancelled") }
        guard command == .finishInterjection, snapshot.isRecording else { return .save }
        return verdictForSavingRecording()
    }

    /// One line at the end of every recording, written while the recorder can still be asked: the audio it
    /// really took in against the time on the clock, the restarts, the route and category, and what happened
    /// to the Margin. `lastVoiceCapture` becomes this line, so a Margin that failed names its cause (#937).
    func recordFinalCaptureDiagnostics(_ outcome: String) {
        guard snapshot.isRecording, !captureWatcher.finalRecorded else { return }
        captureWatcher.finalRecorded = true
        var fields = engine?.recordingCaptureDiagnostics() ?? [:]
        fields["health"] = (captureWatcher.health ?? .capturing).diagnosticName
        fields["restarts"] = String(captureWatcher.restarts)
        fields["watchedCapturedMs"] = String(captureWatcher.capturedMs)
        fields["wallMs"] = String(captureWatcher.elapsedMs)
        fields["outcome"] = outcome
        recordDeveloperDiagnostic("margin.capture.final", fields)
        diagnostics["lastVoiceCapture"] = Self.captureSummary(fields)
    }

    private static func captureSummary(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    /// Save was tapped on a recording that took in no audio: say so, and don't keep an empty voice as a Margin.
    private func discardEmptyRecording() {
        cancelInterjection()
        reportFailure("Nothing was recorded, so no Margin was saved. The microphone didn't pick up any sound. Try again, or write the Margin instead.")
    }

    /// The line after a spoken Margin is saved. A recording the microphone cut short says so.
    func reportMarginSaved(_ verdict: MarginCaptureSupervisor.SaveVerdict) {
        if verdict == .saveCutShort {
            reportWarning("Margin saved, but part of it may be missing. The microphone stopped early.")
        } else {
            reportConfirmation("Margin saved. Transcription is continuing in the background.")
        }
    }

    func beginInterjection() {
        guard !isFinishingInterjection, !isMarginCaptureCoolingDown else { return }
        guard snapshot.skimBridgeState == nil else {
            reportWarning("Margins are unavailable while a scene summary is playing. Pause or cancel Skim first.")
            return
        }
        guard !recordingNavigationIsLocked, handOffPlayingMarginToRecording() else { return }
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
        let status = microphoneAccess.status()
        if status == .granted {
            diagnostics["lastMicrophonePermissionResult"] = "granted"
            microphoneAccess.record { [weak self] in self?.startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID) }
            return
        }
        if let status, microphonePrimer.holds(captureID: voiceCaptureRequestID, status: status) {
            diagnostics["lastMicrophonePermissionResult"] = "primer_shown"
            return
        }
        requestMicrophoneThenRecord(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
    }

    /// #783: Continue on the line before the microphone prompt goes on to iOS's request.
    func continueMicrophonePrimer() {
        guard let captureID = microphonePrimer.continueTapped(),
              pendingVoiceCaptureRequestID == captureID else { return }
        requestMicrophoneThenRecord(requestedAt: Date(), captureID: captureID)
    }

    private func requestMicrophoneThenRecord(requestedAt: Date, captureID voiceCaptureRequestID: UUID) {
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
            }
        }
        guard !snapshot.isRecording else { return }
        recordingPresentationContext = nil
        streamingSpeechQueue.resumeAfterInterjection() // the recorder wouldn't start and the engine put the source back (#1034)
    }

    /// Add a Margin ignores taps while a save is under way and until the listening screen has been drawn and has
    /// stayed for `MarginRestartShield.window`, so the second tap of a double tap on Save can't start a new Margin (#148).
    var isMarginCaptureCoolingDown: Bool { !marginRestartShield.acceptsBegin(at: Date()) }

    /// Publish acknowledgement before synchronous recorder/store finalization.
    /// The save and the draw of the listening screen that follows can outlast any timer started when the save
    /// returns, and the queued second tap arrives after the draw, so the shield waits for `listeningScreenAppeared`.
    func requestFinishInterjection() {
        guard snapshot.isRecording, !isFinishingInterjection else { return }
        isFinishingInterjection = true
        marginRestartShield.saveRequested()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.finishInterjection()
            self.marginRestartShield.saveFinished(at: Date(), stillRecording: self.snapshot.isRecording)
            self.isFinishingInterjection = false
        }
    }

    /// The recording screen has gone and the screen behind it is on screen again: the shield's window starts now.
    func listeningScreenAppeared() {
        marginRestartShield.screenAppeared(at: Date())
    }

    func finishInterjection() {
        guard snapshot.isRecording, let verdict = verdictForSavingRecording() else { return }
        run { engine in
            defer { recordSpokenMarginSavedBeforeFailure(engine.lastScheduledTranscriptionInterjectionId) }
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            transcribeAndRecordSavedSpokenMargin()
            reportMarginSaved(verdict)
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
            refreshMarginRows()
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func recordSavedInterjectionForOnboarding() {
        changeOnboardingProgress { $0.firstInterjectionSaved() }
    }

    func cancelInterjection() {
        if isRequestingRecordingPermission && !snapshot.isRecording {
            microphonePrimer.cancel()
            pendingVoiceCaptureRequestID = nil
            isRequestingRecordingPermission = false
            recordingPresentationContext = nil
            return
        }
        recordFinalCaptureDiagnostics("cancelled")
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
        guard !recordingNavigationIsLocked, !isMarginCaptureCoolingDown else { return } // the pencil sits beside Add a Margin (#148)
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
        microphonePrimer.cancel()
        isRequestingRecordingPermission = false
        pendingVoiceCaptureRequestID = nil
        recordingPresentationContext = nil
        beginWrittenMargin()
    }

    func saveWrittenMargin(text: String) {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.saveWrittenInterjection(captureId: draft.capture.id, text: text)
            listeningSignals.writtenMargin(itemId: draft.capture.itemId, text: text)
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
}

extension MarginCaptureSupervisor.Health {
    /// What the Live Activity and Dynamic Island say about the microphone.
    var liveActivityMicrophone: Gate2LiveActivityMicrophone {
        switch self {
        case .starting: .starting
        case .capturing: .capturing
        case .notCapturing: .stopped
        }
    }
}
