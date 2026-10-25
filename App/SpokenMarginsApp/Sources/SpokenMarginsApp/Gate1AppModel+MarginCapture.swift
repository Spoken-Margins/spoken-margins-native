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
            changed: { [weak self] health, restarts in self?.captureHealthChanged(health, restarts: restarts) },
            holdRecorder: { [weak self] in self?.engine?.pauseRecordingForReadyCue() },
            releaseRecorder: { [weak self] seconds in self?.engine?.resumeRecordingAfterReadyCue(after: seconds) }
        )
    }

    func endCaptureWatch() {
        MarginOutcomeCuePlayer.shared.stop() // a dead microphone's repeating cue ends with the recording (#1977)
        captureWatcher.stop()
        recordingCaptureHealth = .capturing
        gate2CompactControls.setMicrophone(.capturing)
    }

    func captureHealthChanged(_ health: MarginCaptureSupervisor.Health, restarts: Int) {
        let wasCapturing = recordingCaptureHealth == .capturing
        recordingCaptureHealth = health
        gate2CompactControls.setMicrophone(health.liveActivityMicrophone)
        var fields = engine?.recordingCaptureDiagnostics() ?? [:]
        fields["health"] = health.diagnosticName
        fields["restarts"] = String(restarts)
        if let readyCue = captureWatcher.readyCueResult { fields["readyCue"] = readyCue }
        recordDeveloperDiagnostic("margin.capture.health", fields)
        diagnostics["lastVoiceCapture"] = Self.captureSummary(fields)
        switch health {
        case .capturing where !wasCapturing:
            // Recovery from a dead microphone lands here too: the repeating cue ends with it (#1977).
            MarginOutcomeCuePlayer.shared.stop()
            reportSuccess("Recording Margin.")
        case .notCapturing:
            // The source is paused for the recording, so a dead microphone is otherwise silence: say so, softly, until the listener acts (#1977).
            playOutcomeCue(.micStopped)
            reportFailure(captureWatcher.hasKeepableAudio
                ? Self.keptAudioMessage
                : "The microphone isn't recording, so nothing is being saved. Tap Try again, or cancel and write the Margin instead.")
        default:
            MarginOutcomeCuePlayer.shared.stop()
        }
        // The health may be unchanged while only the keepable state flipped: redraw for Try again.
        objectWillChange.send()
    }

    /// The listener tapped Try again on a recording screen that says the microphone isn't recording.
    func retryMicrophone() {
        guard snapshot.isRecording else { return }
        // The new recorder starts inside `retry()`: end the microphone cue first, or its tail opens the new file.
        MarginOutcomeCuePlayer.shared.stop()
        if captureWatcher.retry() {
            lastError = nil
        } else {
            // Speech arrived since the last poll: a restart would delete it. Redraw without Try again.
            if case .notCapturing = captureWatcher.health {
                playOutcomeCue(.micStopped) // nothing restarted, so the microphone is still stopped
                if lastError != Self.keptAudioMessage { reportFailure(Self.keptAudioMessage) }
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
        cancelInterjection(feeling: .warning) // one tap for the miss, not a cancel's and then a warning's
        playOutcomeCue(MarginOutcomeCue(verdict: .discardEmpty))
        reportFailure("Nothing was recorded, so no Margin was saved. The microphone didn't pick up any sound. Try again, or write the Margin instead.")
    }

    /// Every outcome cue goes through here (#1977). When the recorder ended by turning the audio session off, it
    /// handed the session back to another app's audio; a cue would turn it on again and leave that audio
    /// interrupted, so the ending stays silent and the diagnostics key says why.
    private func playOutcomeCue(_ cue: MarginOutcomeCue) {
        if engine?.recordingReleasedAudioSession() == true {
            MarginOutcomeCuePlayer.shared.stop()
            diagnostics["outcomeCue"] = "skipped:session_released"
            return
        }
        diagnostics["outcomeCue"] = MarginOutcomeCuePlayer.shared.play(cue)
    }

    /// Reports interrupted, unexpectedly short or unverified saved audio without claiming a capture cause.
    func reportMarginSaved(_ verdict: MarginCaptureSupervisor.SaveVerdict) {
        let integrity = engine?.finalizedRecordingIntegrity()
        if let integrity { recordDeveloperDiagnostic("margin.capture.finalized", integrity.diagnosticFields) }
        if let integrity, integrity.fileMs == nil {
            AppHaptics.play(.warning)
            playOutcomeCue(.savedMaybeCut)
            reportWarning("Margin saved, but its recording could not be checked. Please play it back.")
        } else if (integrity?.qualifying(verdict) ?? verdict) == .saveCutShort {
            AppHaptics.play(.warning)
            playOutcomeCue(MarginOutcomeCue(verdict: .saveCutShort))
            reportWarning("Margin saved, but part of it may be missing.")
        } else {
            AppHaptics.play(.saved)
            playOutcomeCue(MarginOutcomeCue(verdict: .save))
            reportConfirmation("Margin saved. Transcription is continuing in the background.")
        }
    }

    // The capture state lives in `marginCapture` (#993); these are its old names, read-only. Writes go through it.
    var recordingPresentationContext: RecordingPresentationContext? { marginCapture.presentationContext }
    var isRequestingRecordingPermission: Bool { marginCapture.isRequestingPermission }
    var recordingPermissionDenied: Bool { marginCapture.permissionDenied }
    /// #783: the line shown before iOS's first microphone prompt.
    var microphonePrimer: MicrophonePrimer { marginCapture.primer }
    var isFinishingInterjection: Bool { marginCapture.isFinishing }
    var writtenMarginDraft: WrittenMarginDraft? { marginCapture.writtenDraft }

    func beginInterjection() {
        guard !isFinishingInterjection, !isMarginCaptureCoolingDown else { return }
        guard snapshot.skimBridgeState == nil else {
            reportWarning("Margins are unavailable while a scene summary is playing. Pause or cancel Skim first.")
            return
        }
        guard !recordingNavigationIsLocked, handOffPlayingMarginToRecording() else { return }
        suggestSharedMarginReply()
        let voiceCaptureRequestID = marginCapture.beginVoiceRequest()
        AppHaptics.play(.started)
        statusMessage = "Starting Margin..."
        lastError = nil
        diagnostics["lastInterjectionTap"] = "begin"
        let requestedAt = Date()
        marginCapture.setPresentationContext(RecordingPresentationContext(
            snapshot: snapshot,
            startedAt: requestedAt
        ))
        let status = microphoneAccess.status()
        if status == .granted {
            diagnostics["lastMicrophonePermissionResult"] = "granted"
            pauseSourceOnTap(requestedAt: requestedAt)
            microphoneAccess.record { [weak self] in self?.startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID) }
            return
        }
        if let status, marginCapture.holdForPrimer(captureID: voiceCaptureRequestID, status: status) {
            diagnostics["lastMicrophonePermissionResult"] = "primer_shown"
            return
        }
        requestMicrophoneThenRecord(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
    }

    /// #1696: a playing podcast stops on the tap itself, before the deferred start and the engine's anchor work,
    /// so the listener never talks over it however long the start takes. Cancel (or a failed start) puts it back.
    private func pauseSourceOnTap(requestedAt: Date) {
        guard let engine else { return }
        snapshot = engine.pauseSourceForInterjection(request: .tapped(at: requestedAt))
    }

    /// The Margin ended before the recorder was asked for (Cancel, or a start that failed): a podcast the tap
    /// paused plays on from where it stopped. Nothing to do when the tap paused nothing.
    private func resumeSourcePausedOnTap() {
        guard let engine, engine.hasPendingInterjectionPause else { return }
        run { snapshot = try $0.abandonPendingInterjection() }
    }

    /// #783: Continue on the line before the microphone prompt goes on to iOS's request.
    func continueMicrophonePrimer() {
        guard let captureID = marginCapture.continuePrimer() else { return }
        requestMicrophoneThenRecord(requestedAt: Date(), captureID: captureID)
    }

    private func requestMicrophoneThenRecord(requestedAt: Date, captureID voiceCaptureRequestID: UUID) {
        Task {
            let granted = await requestMicrophonePermission()
            switch marginCapture.resolvePermission(for: voiceCaptureRequestID, granted: granted) {
            case .stale:
                return
            case .denied:
                resumeHeldMarginVoice(heldMarginVoice) // no recording will come of it: the Margin it paused plays on (#1672)
                reportFailure("Microphone access is required to record Margins. Enable microphone access in Settings and try again.")
            case .granted:
                startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
            }
        }
    }

    private func startInterjectionRecording(requestedAt: Date, captureID: UUID) {
        guard marginCapture.claimStart(for: captureID) else { return }
        defer { marginCapture.releaseStart() }
        synchronizeStreamingSpeechAnchorIfNeeded()
        streamingSpeechQueue.pauseForInterjection()
        run { engine in
            snapshot = try engine.beginInterjection(request: .tapped(at: requestedAt).replying(to: marginCapture.pendingReply?.link))
            if snapshot.isRecording {
                marginCapture.setPresentationContext(RecordingPresentationContext(
                    snapshot: snapshot,
                    startedAt: Date()
                ))
                let latencyMs = max(0, Int(Date().timeIntervalSince(requestedAt) * 1000))
                diagnostics["lastInterjectionRecordingStartLatencyMs"] = "\(latencyMs)"
            }
        }
        guard !snapshot.isRecording else { return }
        resumeSourcePausedOnTap() // a start that failed before the engine took over the pause
        marginCapture.clearPresentationContext()
        resumeHeldMarginVoice(heldMarginVoice) // no recording came of it: the Margin it paused plays on (#1672)
        streamingSpeechQueue.resumeAfterInterjection() // the recorder wouldn't start and the engine put the source back (#1034)
    }

    /// Add a Margin ignores taps while a save is under way and until the listening screen has been drawn and has
    /// stayed for `MarginRestartShield.window`, so the second tap of a double tap on Save can't start a new Margin (#148).
    var isMarginCaptureCoolingDown: Bool { marginCapture.isCoolingDown(at: Date()) }

    /// Publish acknowledgement before synchronous recorder/store finalization.
    /// The save and the draw of the listening screen that follows can outlast any timer started when the save
    /// returns, and the queued second tap arrives after the draw, so the shield waits for `listeningScreenAppeared`.
    func requestFinishInterjection() {
        guard snapshot.isRecording, marginCapture.requestFinish() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.hangTelemetry.labels.scoped("marginSaveFinish") {
                self.finishInterjection()
                self.marginCapture.finalizeFinish(at: Date(), stillRecording: self.snapshot.isRecording)
            }
        }
    }

    /// The recording screen has gone and the screen behind it is on screen again: the shield's window starts now.
    func listeningScreenAppeared() {
        marginCapture.screenAppeared(at: Date())
    }

    func finishInterjection() {
        guard snapshot.isRecording, let verdict = verdictForSavingRecording() else { return }
        let held = heldMarginVoice // a Margin recorded over a voice leaves the source paused for it to play on (#1672)
        run { engine in
            defer { recordSpokenMarginSavedBeforeFailure(engine.lastScheduledTranscriptionInterjectionId) }
            snapshot = try engine.finishInterjection(audioRef: nil, resumesSource: held == nil)
            if held?.kind == .own { noteMarginRecordedOverHeldOwnMargin(engine.lastScheduledTranscriptionInterjectionId) }
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            transcribeAndRecordSavedSpokenMargin()
            reportMarginSaved(verdict)
        }
        if !snapshot.isRecording {
            marginCapture.clearPresentationContext()
            refreshMarginRows()
            resumeHeldMarginVoice(held)
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func recordSavedInterjectionForOnboarding() {
        changeOnboardingProgress { $0.firstInterjectionSaved() }
    }

    func cancelInterjection() { cancelInterjection(feeling: .ended) }

    /// `feeling` is the one tap the cancel makes: a plain cancel ends softly, a discarded empty recording warns.
    func cancelInterjection(feeling: HapticKind) {
        let held = heldMarginVoice
        if isRequestingRecordingPermission && !snapshot.isRecording {
            marginCapture.abandonVoiceRequest()
            resumeSourcePausedOnTap()
            resumeHeldMarginVoice(held)
            return
        }
        recordFinalCaptureDiagnostics("cancelled")
        run { engine in
            snapshot = try engine.cancelInterjection(resumesSource: held == nil)
            refreshSelectedItem()
            AppHaptics.play(feeling)
            reportSuccess("Cancelled Margin.")
        }
        if !snapshot.isRecording {
            marginCapture.clearPresentationContext()
            resumeHeldMarginVoice(held)
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func beginWrittenMargin() { beginWrittenMargin(answering: nil) }

    /// A written Margin that answers a shared one when `reply` is set (#473).
    func beginWrittenMargin(answering explicitReply: MarginReplyDraft?) {
        let reply = explicitReply ?? sharedMarginThisMarginAnswers() // heard over it or just before (#473)
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
            let capture = try engine.beginWrittenInterjection(replyTo: reply?.link)
            lastError = nil
            marginCapture.clearPermissionDenied()
            snapshot = engine.snapshot
            marginCapture.openDraft(makeWrittenMarginDraft(for: capture, store: store, replyChoice: MarginReplyChoice(suggested: reply)))
            marginCapture.clearPresentationContext()
        } catch {
            streamingSpeechQueue.resumeAfterInterjection()
            reportFailure(error, context: "Written Margin could not start")
        }
    }

    /// The draft the written Margin screen opens with, for a capture the engine has locked to its place.
    func makeWrittenMarginDraft(for capture: WrittenInterjectionCapture, store: SQLiteSessionStore, replyChoice: MarginReplyChoice) -> WrittenMarginDraft {
        WrittenMarginDraft(
            capture: capture,
            text: "",
            itemTitle: (try? store.loadItem(id: capture.itemId).title) ?? "Current item",
            targetDescription: capture.targetType == .item ? "Source" : (capture.targetType == .assistantTurn ? "Assistant response" : "Margin summary"),
            progressPercent: capture.roughPercent,
            replyChoice: replyChoice
        )
    }

    /// #1669: Write instead, while a Margin is recording. What was recorded is dropped (the listener confirmed that
    /// first when there was something worth keeping) and the written Margin opens at the place the recording was
    /// locked to, answering the same shared Margin. A voice the recording held stays where it is, and the source stays
    /// paused under it, as when the listener switches before the recording starts.
    func switchRecordingToWrittenMargin() {
        guard snapshot.isRecording, !isFinishingInterjection, let engine else { return }
        let replyChoice = marginCapture.replyChoice
        let held = heldMarginVoice
        recordFinalCaptureDiagnostics("switched_to_written")
        do {
            let store = try requireStore()
            let capture = try engine.switchRecordingToWrittenInterjection(resumesSource: held == nil)
            snapshot = engine.snapshot // the screen leaves the recording, and the capture watch ends with it
            lastError = nil
            marginCapture.clearPermissionDenied()
            marginCapture.openDraft(makeWrittenMarginDraft(for: capture, store: store, replyChoice: replyChoice))
            marginCapture.clearPresentationContext()
            marginVoiceHeldForRecording = nil // no recording is coming, so a Margin of any kind stays as it is (#1672)
            if held?.kind == .shared { stopImportedCommentaryPlayback(resumeSource: false) }
            if !capture.wasPlaying { streamingSpeechQueue.resumeAfterInterjection() } // a finished source has no Save to resume it
        } catch {
            reportFailure(error, context: "Couldn't switch to writing")
        }
    }

    func updateWrittenMarginText(_ text: String) {
        guard writtenMarginDraft != nil else { return }
        marginCapture.setDraftText(text)
        journalWrittenMarginText()
    }

    func switchPendingVoiceCaptureToWrittenMargin() {
        guard isRequestingRecordingPermission, !snapshot.isRecording else { return }
        marginCapture.abandonVoiceRequest()
        let heldShared = heldMarginVoice?.kind == .shared
        marginVoiceHeldForRecording = nil // no recording is coming, so a Margin of any kind stays as it is and nothing is left to play it on (#1672)
        if heldShared { stopImportedCommentaryPlayback(resumeSource: false) } // a card up blocks writing; the Margin is let go, as Add a Margin used to do
        beginWrittenMargin()
        if writtenMarginDraft == nil { resumeSourcePausedOnTap() } // the pencil refused: nothing else will put the source back
    }

    func saveWrittenMargin(text: String) {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.saveWrittenInterjection(captureId: draft.capture.id, text: text)
            listeningSignals.writtenMargin(itemId: draft.capture.itemId, text: text)
            marginCapture.closeDraft()
            clearWrittenMarginJournal(captureId: draft.capture.id)
            if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
            refreshSelectedItem()
            refreshMarginRows()
            if draft.priorWasPlaying && snapshot.status == .paused {
                AppHaptics.play(.warning)
                reportWarning("Margin saved. Playback is paused; tap Play to continue.")
            } else {
                AppHaptics.play(.saved)
                reportConfirmation("Written Margin saved.")
            }
        } catch {
            marginCapture.setDraftText(text)
            reportFailure(error, context: "Written Margin could not be saved")
        }
    }

    func cancelWrittenMargin() {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.cancelWrittenInterjection(captureId: draft.capture.id)
            marginCapture.closeDraft()
            clearWrittenMarginJournal(captureId: draft.capture.id)
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
