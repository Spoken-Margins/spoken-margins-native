import Foundation
import SessionKit

/// The model's side of `HangTelemetry` (#2099).
extension Gate1AppModel {
    /// Called when the app comes to the front: starts the probe the first time, and puts it at its in-front pace.
    func startHangTelemetry() {
        guard !Self.isRunningUnitTests else { return }
        defer { hangTelemetry.setForeground(true) }
        hangTelemetry.start(
            record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
            context: { [weak self] in
                guard let self else { return [:] }
                return ["screen": String(describing: self.screen), "status": self.snapshot.status.rawValue]
            }
        )
    }

    /// What the Play/Pause button shows, so a tap on a pending start reads as the cancel it is (#2098).
    var playPauseFace: PlayPauseFace {
        // The branches of `playPause()` that take the tap before the source does.
        let tapReachesTheSource = playingImportedCommentary == nil
            && marginMomentConductor?.isPlayingVoice != true
            && !ownMarginVoiceHasTransport
            && snapshot.skimBridgeState == nil
            && snapshot.phase != .finished
        return PlayPauseFace(status: snapshot.status, isPlaying: activePlaybackIsPlaying, tapReachesTheSource: tapReachesTheSource)
    }

    /// The Play/Pause button on the mini player and the full player. It logs the tap like the Lock Screen
    /// and compact commands do (`origin: app_ui`), then does what the button did before.
    func playPauseTapped() {
        recordDeveloperDiagnostic("transport.request", [
            "command": CompactControlCommand.togglePlayPause.rawValue, "origin": "app_ui",
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1),
            "requestedMediaTimeMs": "-1"
        ])
        hangTelemetry.noteTap(command: CompactControlCommand.togglePlayPause.rawValue, status: snapshot.status.rawValue)
        // The recording screen is what the listener sees then, and it hides banners, so the refusal is logged instead.
        if marginVoiceIsHeldForRecording {
            recordDeveloperDiagnostic("transport.refused", ["command": CompactControlCommand.togglePlayPause.rawValue, "reason": "margin_recording"])
        }
        hangTelemetry.labels.scoped("playPauseTapped") { playPause() }
    }

    /// The pill's play button on a finished item, which starts the item again.
    func finishedPlayTapped(id: String) {
        recordDeveloperDiagnostic("transport.request", [
            "command": "restartFinished", "origin": "app_ui",
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1), "requestedMediaTimeMs": "-1"
        ])
        hangTelemetry.noteTap(command: "restartFinished", status: snapshot.status.rawValue)
        startNewSession(id: id)
    }

    /// Called when the playback status changes: closes the wait of a tap that caused it.
    func recordTapAnswer(previous: SessionSnapshot) {
        guard previous.status != snapshot.status,
              let answer = hangTelemetry.statusChanged(to: snapshot.status.rawValue) else { return }
        recordDeveloperDiagnostic(TapToStateTracker.eventKind, answer)
    }

    /// The outcome of the mini player's X, the moment it is decided. The tap itself is logged as
    /// `miniPlayer.close`; a late or refused close looks the same as an accepted one without this.
    func recordMiniPlayerCloseOutcome(_ outcome: String) {
        recordDeveloperDiagnostic("miniPlayer.close.outcome", ["outcome": outcome])
        if outcome == "accepted" { hangTelemetry.closeTapped() }
    }

    // MARK: Snapshot changes

    /// What follows a change of the playback snapshot. `snapshot`'s `didSet` calls it under the `snapshotChanged`
    /// label, and each step that can wait has its own, so a hang in a tap or an audio callback names the step
    /// instead of reading `none` (#2967).
    func snapshotDidChange(from oldValue: SessionSnapshot) {
        let labels = hangTelemetry.labels
        labels.scoped("snapshot.playbackEvents") { recordPlaybackEventState(previous: oldValue) }
        if oldValue.sessionId != snapshot.sessionId { resumeDeferredPodcastPlacements() }
        if oldValue.isRecording, !snapshot.isRecording { endCaptureWatch() }
        if !oldValue.isRecording, snapshot.isRecording { startCaptureWatch() }
        settleSpeechInterruptionResume()
        labels.scoped("snapshot.listeningSignals") {
            listeningSignals.snapshotChanged(from: oldValue, to: snapshot); playQueueSnapshotChanged(from: oldValue, to: snapshot)
        }
        updateNarrationVoiceNotice()
        if playingImportedCommentary != nil,
           oldValue.sessionId != snapshot.sessionId || oldValue.itemId != snapshot.itemId
            || oldValue.targetId != snapshot.targetId || snapshot.status.isPlaybackActive {
            stopImportedCommentaryPlayback(resumeSource: false)
        }
        if snapshot.status.isPlaybackActive { releaseOwnMarginReturn(); libraryAudioLoop.renderPolicy.noteListenerEngaged() }
        if let status = snapshot.preparedTextAudioStatus, status != preparedTextAudioStatus { preparedTextAudioStatus = status } // an equal write still publishes
        if let snapshotSourceTranscriptStatus = snapshot.sourceTranscriptStatus, snapshotSourceTranscriptStatus != sourceTranscriptStatus,
           !(sourceTranscriptStatus == "transcribing" && snapshotSourceTranscriptStatus == "not_started") {
            sourceTranscriptStatus = snapshotSourceTranscriptStatus
        }
        if oldValue.status.isPlaybackActive != snapshot.status.isPlaybackActive || oldValue.itemId != snapshot.itemId {
            if !canPrepareLibraryAudio {
                libraryAudioLoop.cancelOnly()
            } else {
                labels.scoped("snapshot.audioPreparation") { startForegroundAudioPreparationIfNeeded() }
            }
        }
        reconcilePlaybackProgressTicker()
        labels.scoped("snapshot.narrationProtection") { reconcileNarrationStartupProtection() }
        labels.scoped("snapshot.skimAvailability") { updateSkimAvailability(refreshResources: false) }
        updateGate2CompactState()
    }

    /// `engine.run:finishInterjection` for `finishInterjection()`. A stack label holds 40 characters.
    nonisolated static func engineRunLabel(caller: StaticString) -> String {
        let name = "\(caller)".prefix { $0 != "(" }
        return name.isEmpty ? "engine.run" : String("engine.run:\(name)".prefix(40))
    }
}
