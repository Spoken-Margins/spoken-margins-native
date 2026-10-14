import Foundation
import SessionKit
import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Own and shared Margin voice playback, prompts and source return. Moved out of `Gate1AppModel.swift` unchanged (#987).
/// The transport (player, poll, chime, system transport, health) is `MarginVoicePlayer` (#993); what stays here is the
/// orchestration around it, in the order it always ran: pausing and resuming the source, the return claim, offers,
/// the autoplay task, heard persistence, and the hand-off of system transport.
extension Gate1AppModel {
    /// The voice player's published state, as the model's own names. The player holds the canonical values.
    var playingImportedCommentary: ImportedCommentaryPrompt? { marginVoicePlayer.sharedMargin }
    var importedCommentaryIsPaused: Bool { marginVoicePlayer.sharedIsPaused }
    /// What the shared Margin's voice is really doing (#941), judged from the player, not from the request to play.
    var importedCommentaryPhase: SharedMarginPlaybackPhase { marginVoicePlayer.sharedPhase }
    var playingInterjectionAudioId: String? { marginVoicePlayer.ownMarginID }
    var playingInterjectionAudioSessionID: String? { marginVoicePlayer.ownMarginSessionID }
    var playingInterjectionAudioRate: Double { marginVoicePlayer.rate }

    func isPlayingInterjectionAudio(_ interjection: Interjection) -> Bool {
        marginVoicePlayer.isPlayingOwn(interjection)
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
        // The source comes back when this Margin ends if playing it is what paused it (#1538); read before the pause.
        // A voice that is already playing (another of your Margins, or a shared one) holds the promise made for it.
        let returnsSource = snapshot.status.isPlaybackActive || sharedMarginReturn.heldByVoice
        if snapshot.status.isPlaybackActive {
            pause()
        }
        stopInterjectionAudioPlayback()
        do {
            try marginVoicePlayer.startOwn(
                interjection,
                url: { leveledMarginURL(url, itemId: interjection.itemId, anchorMediaTimeMs: interjection.anchor.mediaTimeMs) },
                rate: Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            )
            sharedMarginReturn.voiceStarted(returnToSource: returnsSource)
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
        marginVoicePlayer.resetSharedState()
        sharedMarginReturn.voiceStopped()
        if hadImportedMargin {
            marginVoicePlayer.endRemoteControls()
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
        }
        marginVoicePlayer.releasePlayer()
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
            try marginVoicePlayer.prepareShared(
                prompt,
                url: { leveledMarginURL(audioURL, itemId: prompt.layer.itemId, anchorMediaTimeMs: prompt.interjection.resolution.localMediaTimeMs) },
                rate: Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate),
                mixesWithOtherAudio: mixesWithOtherAudio,
                lowersBackgroundAudio: lowersBackgroundAudio,
                mixedPlaybackVolume: mixedPlaybackVolume
            )
            pendingImportedCommentary = nil
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(false)
            gate2CompactControls.setNowPlayingEnabled(false)
            gate2CompactControls.endLiveActivities()
            marginVoicePlayer.beginShared(installRemoteControls: !mixesWithOtherAudio)
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
        marginVoicePlayer.forgetSharedMargin()
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
        do { try marginVoicePlayer.playCue() } catch {
            diagnostics["importedCommentaryCue"] = "failed:\(error.localizedDescription)"
        }
        #endif
    }
}

extension Gate1AppModel: MarginVoicePlayerHost {
    var marginVoiceMixesWithOtherAudio: Bool { mixesWithOtherAudio }

    /// Your Margin played to its end. When playing it paused the source, the source plays again, and on a podcast the
    /// item's later spoken Margins follow as playback reaches them (owner's call on #1538). A stop the listener asks
    /// for, a recording or a failure never gets here, so none of them resumes anything.
    func marginVoiceOwnPlaybackEnded() {
        let playedID = playingInterjectionAudioId, playedSessionID = playingInterjectionAudioSessionID
        let returnsSource = sharedMarginReturn.returnsSourceWhenVoiceEnds(resumeSource: true)
        stopInterjectionAudioPlayback()
        guard returnsSource, snapshot.status == .paused else { return }
        resumePlayback()
        if let playedID, let playedSessionID {
            continueWithLaterMargins(afterOwnMarginID: playedID, sessionID: playedSessionID)
        }
    }

    /// A podcast has no later Margins to wait for unless the listener recorded some. An article just resumes.
    private func continueWithLaterMargins(afterOwnMarginID id: String, sessionID: String) {
        guard let store, let itemID = snapshot.itemId, let position = snapshot.currentMediaTimeMs,
              let played = (try? store.loadInterjections(sessionId: sessionID))?.first(where: { $0.id == id }),
              played.itemId == itemID,
              played.isInlineSpokenMargin, let playedMs = played.anchor.mediaTimeMs else { return }
        let spoken = inlineSpokenMargins(itemId: itemID, store: store)
        let playedIdentity = Self.marginIdentity(played)
        let anchors = spoken.map { MarginMomentAnchor(marginId: Self.marginIdentity($0), mediaTimeMs: $0.anchor.mediaTimeMs ?? 0) }
        guard anchors.contains(where: { $0.marginId != playedIdentity && $0.mediaTimeMs > position }) else { return }
        var voiceURLs: [String: URL] = [:]
        for margin in spoken {
            if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }
        }
        endMarginMoment()
        startMarginMoment(
            itemId: itemID,
            target: MarginMomentAnchor(marginId: playedIdentity, mediaTimeMs: playedMs),
            otherMargins: anchors,
            voiceURLs: voiceURLs,
            title: "Your Margin",
            isApproximate: false,
            resumingAtMediaTimeMs: position
        )
    }

    func marginVoiceOwnPlaybackFailed() {
        stopInterjectionAudioPlayback()
        reportFailure("This Margin's audio couldn't be played.")
    }

    func marginVoiceSharedMarginHeard(_ margin: ImportedCommentaryInterjection) {
        markSharedMarginHeard(margin)
    }

    func marginVoiceSharedPlaybackEnded() {
        stopImportedCommentaryPlayback(resumeSource: true)
    }

    func marginVoiceRemoteCommand(_ command: CompactControlCommand) {
        dispatchGate2CompactCommand(command, origin: "imported_margin_remote")
    }
}
