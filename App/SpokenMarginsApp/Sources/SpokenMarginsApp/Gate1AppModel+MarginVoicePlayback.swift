import Foundation
import SessionKit
import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Own and shared Margin voice playback, prompts and source return. Moved out of `Gate1AppModel.swift` unchanged (#987).
extension Gate1AppModel {
    func isPlayingInterjectionAudio(_ interjection: Interjection) -> Bool {
        playingInterjectionAudioId == interjection.id && playingInterjectionAudioSessionID == interjection.sessionId
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
            let item = AVPlayerItem(url: leveledMarginURL(url, itemId: interjection.itemId, anchorMediaTimeMs: interjection.anchor.mediaTimeMs))
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
        importedCommentaryHealth = nil
        importedCommentaryPhase = .loading
        sharedMarginReturn.voiceStopped()
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
        let shouldResume = sharedMarginReturn.promptDismissed()
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

    func listenToImportedCommentary(_ prompt: ImportedCommentaryPrompt) {
        sharedMarginOffers.remove(id: prompt.id)
        #if canImport(AVFoundation)
        guard let audioPath = prompt.interjection.audioPath,
              let audioURL = resolvedApplicationSupportAssetURL(for: audioPath) else {
            dismissPendingImportedCommentary()
            reportFailure("This shared Margin contains reviewed text but no playable voice recording.")
            return
        }
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        let shouldResumeSource = sharedMarginReturn.listenRequested(
            sourceIsPlaying: snapshot.status.isPlaybackActive,
            voiceIsPlaying: playingImportedCommentary != nil
        )
        if snapshot.status.isPlaybackActive { pause() }
        stopInterjectionAudioPlayback()
        sharedMarginReturn.voiceStarted(returnToSource: shouldResumeSource)
        do {
            #if os(iOS)
            let options: AVAudioSession.CategoryOptions = mixesWithOtherAudio
                ? (lowersBackgroundAudio ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]) : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: leveledMarginURL(audioURL, itemId: prompt.layer.itemId, anchorMediaTimeMs: prompt.interjection.resolution.localMediaTimeMs))
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.volume = mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1
            let rate = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            player.defaultRate = Float(rate)
            interjectionAudioPlayer = player
            playingInterjectionAudioRate = rate
            playingImportedCommentary = prompt
            importedCommentaryIsPaused = false
            let health = SharedMarginPlaybackHealth(startedAt: ProcessInfo.processInfo.systemUptime)
            importedCommentaryHealth = health
            importedCommentaryPhase = health.phase
            let attempt = health.attemptID
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
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item, weak player] in
                var heard = false
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(200))
                    // A reading from a replaced or retried attempt must not touch the current one.
                    guard !Task.isCancelled, let self, self.importedCommentaryHealth?.attemptID == attempt else { return }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    // Heard once the voice has played; a file that fails to decode stays new (#690).
                    if !heard, current.isFinite, current > 0 { heard = true; self.markSharedMarginHeard(prompt.interjection) }
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self.stopImportedCommentaryPlayback(resumeSource: true)
                        return
                    }
                    let failed = item.status == .failed || player?.status == .failed
                    self.observeImportedCommentary(playerFailed: failed, clockSeconds: current, playerAtRest: player?.timeControlStatus == .paused)
                    if self.importedCommentaryPhase.isFailed { return }
                    self.publishImportedCommentaryNowPlaying()
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

    /// Its voice started playing, so the shared Margin is no longer new to this listener (#469).
    func markSharedMarginHeard(_ margin: ImportedCommentaryInterjection) {
        guard margin.isNewToListener, let heard = try? store?.markImportedCommentaryInterjectionHeard(id: margin.id, at: Date()) else { return }
        selectedItem.importedCommentaryInterjections = SharedMarginHearing.replacing(heard, in: selectedItem.importedCommentaryInterjections)
        sharedMarginRows = sharedMarginRows.map { $0.interjection.id == heard.id ? SharedMarginRow(interjection: heard, layer: $0.layer, itemTitle: $0.itemTitle, placement: $0.placement) : $0 }
    }

    func stopImportedCommentaryPlayback(resumeSource: Bool) {
        let shouldResume = sharedMarginReturn.returnsSourceWhenVoiceEnds(resumeSource: resumeSource)
        stopInterjectionAudioPlayback()
        playingImportedCommentary = nil
        sharedMarginReturn.voiceStopped()
        if shouldResume, snapshot.status == .paused { resumePlayback() }
    }

    func reconcileImportedCommentary(previous: SessionSnapshot, current: SessionSnapshot) {
        // Margins crossed together are offered one after another (#918).
        guard let prompt = sharedMarginOffers.nextOffer(
            previous: previous, current: current, selectedItemID: selectedItem.id,
            canOffer: pendingImportedCommentary == nil && playingImportedCommentary == nil,
            prompts: importedCommentaryPrompts(includeAnnounced: true)
        ) else { return }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: current.status.isPlaybackActive)
    }

    private func presentImportedCommentaryPrompt(
        _ prompt: ImportedCommentaryPrompt,
        sourceWasPlaying: Bool
    ) {
        sharedMarginReturn.promptShown(sourceWasPlaying: sourceWasPlaying)
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
        sharedMarginOffers.markAnnounced(prompt.id)
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

    nonisolated static func marginPlaybackRate(itemPlaybackRate: Double) -> Double {
        guard itemPlaybackRate.isFinite else { return 1 }
        return max(0.25, min(3, itemPlaybackRate))
    }

    private func playImportedCommentaryCue() {
        #if canImport(AVFoundation)
        do { commentaryCuePlayer = try SharedMarginChime.play() } catch {
            diagnostics["importedCommentaryCue"] = "failed:\(error.localizedDescription)"
        }
        #endif
    }
}
