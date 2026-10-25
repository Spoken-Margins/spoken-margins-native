import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
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
        // A moment's voice that has the floor stops first (#1671); the item it was holding paused carries on after.
        let cutMomentVoice = endMarginMomentVoiceIfPlaying()
        // The source comes back when this Margin ends if playing it is what paused it (#1538); read before the pause.
        // A voice that is already playing (another of your Margins, or a shared one) holds the promise made for it.
        let returnsSource = snapshot.status.isPlaybackActive || sharedMarginReturn.heldByVoice || cutMomentVoice
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
            recordMarginVoiceRate("own")
            recordMarginVoiceEvent("start", player: "own") // after the start call, so a start that throws logs no start
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

    /// While your own Margin plays, the source is the Margin's to bring back only if it stays paused. The listener
    /// resuming it (Lock Screen, headphones) or a sleep timer ending the listening takes it out of the voice's hands (#1538).
    func releaseOwnMarginReturn() {
        guard playingInterjectionAudioId != nil else { return }
        sharedMarginReturn.voiceStopped()
    }

    func stopInterjectionAudioPlayback() {
        let hadImportedMargin = playingImportedCommentary != nil
        if hadImportedMargin { recordMarginVoiceEvent("stop", player: "shared") }
        else if playingInterjectionAudioId != nil { recordMarginVoiceEvent("stop", player: "own") }
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
        let cutMomentVoice = endMarginMomentVoiceIfPlaying() // one Margin voice at a time (#1671)
        let shouldResumeSource = sharedMarginReturn.listenRequested(
            sourceIsPlaying: snapshot.status.isPlaybackActive || cutMomentVoice,
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
            recordMarginVoiceEvent("start", player: "shared") // after the start call, so a start that throws logs no start
            pendingImportedCommentary = nil
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(false)
            gate2CompactControls.setNowPlayingEnabled(false)
            gate2CompactControls.endLiveActivities()
            marginVoicePlayer.beginShared(installRemoteControls: !mixesWithOtherAudio)
            recordMarginVoiceRate("shared")
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
        if marginVoiceHeldForRecording?.kind == .shared { marginVoiceHeldForRecording = nil } // nothing is held once the voice is gone (#1672)
        let shouldResume = sharedMarginReturn.returnsSourceWhenVoiceEnds(resumeSource: resumeSource)
        stopInterjectionAudioPlayback()
        marginVoicePlayer.forgetSharedMargin()
        sharedMarginReturn.voiceStopped()
        if shouldResume, snapshot.status == .paused { resumePlayback() }
    }

    func reconcileImportedCommentary(previous: SessionSnapshot, current: SessionSnapshot) {
        // Margins crossed together are offered one after another (#918). None is offered over a review of new
        // Margins (#474): its lead-ins cross Margins already heard, and an offer would pause the review.
        guard let prompt = sharedMarginOffers.nextOffer(
            previous: previous, current: current, selectedItemID: selectedItem.id,
            canOffer: pendingImportedCommentary == nil && playingImportedCommentary == nil
                && marginMomentConductor?.sequence.isReview != true
                && marginMomentConductor?.isPlayingVoice != true, // a moment's voice is not cut mid-sentence (#1671)
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
                guard !Task.isCancelled, let self,
                      self.pendingImportedCommentary?.id == prompt.id else { return }
                self.hangTelemetry.labels.scoped("importedCommentaryAutoPlay") { self.listenToPendingImportedCommentary() }
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

    /// Only one Margin voice sounds at a time (#1671). A moment's voice is the conductor's own player, apart from
    /// `marginVoicePlayer`, so starting a Margin through the other route has to stop it. True when the voice was
    /// sounding, so the source it held paused is the Margin's to bring back; a voice the listener had paused leaves
    /// everything paused, as before (#1538). The stop is logged by `endMarginMoment`.
    @discardableResult
    func endMarginMomentVoiceIfPlaying() -> Bool {
        guard let conductor = marginMomentConductor, conductor.isPlayingVoice else { return false }
        let wasSounding = !conductor.isVoicePaused
        endMarginMoment()
        return wasSounding
    }

    /// A moment's voice is about to start (the conductor calls this before each voice): a Margin voice from the other
    /// player stops first, then the audio session is set for speech (#1671).
    func prepareMarginMomentVoice() throws {
        if playingImportedCommentary != nil || playingInterjectionAudioId != nil { stopInterjectionAudioPlayback() }
        if !momentVoiceIsOpenInLog { recordMarginVoiceEvent("start", player: "moment") } // not on a resume
        #if os(iOS)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// The moment's voice is over (it ended, was skipped, failed to load or was cut): log its stop once. Called from
    /// every route that ends it, so the log shows which players overlapped (#1671).
    func recordMarginMomentVoiceEnded() {
        if momentVoiceIsOpenInLog { recordMarginVoiceEvent("stop", player: "moment") }
    }

    /// The log's last moment entry is a start with no stop after it.
    private var momentVoiceIsOpenInLog: Bool {
        let events = diagnostics["marginVoice.events"]?.components(separatedBy: " | ") ?? []
        return events.last { $0.hasSuffix(":moment") } == "start:moment"
    }

    /// Diagnostics keep the last ten Margin voice starts and stops with the player that made them (own, shared or
    /// moment), oldest first, so a report of two voices at once names the two players (#1671).
    func recordMarginVoiceEvent(_ event: String, player: String) {
        let events = (diagnostics["marginVoice.events"]?.components(separatedBy: " | ") ?? []) + ["\(event):\(player)"]
        runtimeDiagnostics.keep("marginVoice.events", events.suffix(10).joined(separator: " | "))
    }

    /// Jumps to a Margin's place in its own session, then plays the source at the speed the listener has set. The
    /// session comes back at the rate it last played at (a text item's 1.5×, say) while the screen shows the global
    /// media rate, so without this the source and the Margin's voice played faster than the 1× shown (#1670).
    func playAnchorAtShownRate(_ interjection: Interjection, engine: SessionEngine) throws -> SessionSnapshot {
        try applyPreferredPlaybackRate(to: try engine.playInterjectionAnchor(interjection), engine: engine)
    }

    /// The speed a Margin voice plays at, next to the source's and the one shown, so Diagnostics can say whether what
    /// was heard matched the screen (#1670). `source` is what the session asked for; `player` is read back from the
    /// podcast player itself (n/a when the client can't tell), and `voicePlayer` from the Margin voice's own player.
    @discardableResult
    func recordMarginVoiceRate(_ kind: String) -> Double {
        let voice = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
        func text(_ rate: Double?) -> String { rate.map { String(format: "%.2f", $0) } ?? "n/a" }
        let sourcePlayer = (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.currentPlayerRate()
        let voicePlayer = marginVoicePlayer.currentPlayer.map { Double($0.rate) }
        diagnostics["marginVoice.rate"] = String(
            format: "%@;voice=%.2f;source=%.2f;shown=%.2f;player=%@;voicePlayer=%@", kind, voice, snapshot.playbackRate,
            isMediaPlaybackSnapshot ? mediaPlaybackRate : speechPlaybackRateMultiplier, text(sourcePlayer), text(voicePlayer))
        return voice
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
        let recordedOver = marginVoicePlayer.ownRecordedOverMarginIdentities
        let returnsSource = sharedMarginReturn.returnsSourceWhenVoiceEnds(resumeSource: true)
        stopInterjectionAudioPlayback()
        guard returnsSource, snapshot.status == .paused else { return }
        resumePlayback()
        if let playedID, let playedSessionID {
            continueWithLaterMargins(afterOwnMarginID: playedID, sessionID: playedSessionID, skipping: recordedOver)
        }
    }

    /// A podcast has no later Margins to wait for unless the listener recorded some. An article just resumes.
    private func continueWithLaterMargins(afterOwnMarginID id: String, sessionID: String, skipping recordedOver: Set<String>) {
        guard let store, let itemID = snapshot.itemId, let position = snapshot.currentMediaTimeMs,
              let played = (try? store.loadInterjections(sessionId: sessionID))?.first(where: { $0.id == id }),
              played.itemId == itemID,
              played.isInlineSpokenMargin, let playedMs = played.anchor.mediaTimeMs else { return }
        let spoken = inlineSpokenMargins(itemId: itemID, store: store)
        let playedIdentity = Self.marginIdentity(played)
        // The Margin just recorded over this one (#1672) sits at its place; the listener just made it, so it doesn't play next.
        let anchors = spoken.map { MarginMomentAnchor(marginId: Self.marginIdentity($0), mediaTimeMs: $0.anchor.mediaTimeMs ?? 0) }
            .filter { !recordedOver.contains($0.marginId) }
        guard anchors.contains(where: { $0.marginId != playedIdentity && $0.mediaTimeMs > position }) else { return }
        var voiceURLs: [String: URL] = [:]
        for margin in spoken {
            if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }
        }
        endMarginMoment()
        startMarginMoment(
            sequence: MarginMomentSequence(
                itemId: itemID,
                resumingAtMediaTimeMs: position,
                playedMargin: MarginMomentAnchor(marginId: playedIdentity, mediaTimeMs: playedMs),
                otherMargins: anchors
            ),
            voiceURLs: voiceURLs,
            title: "Your Margin",
            isApproximate: false,
            listening: true
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

/// "Play this moment" for your own spoken Margins, moved out of `Gate1AppModel.swift` (hot-file ratchet, #1538), now with its clock (#1577).
extension Gate1AppModel {
    /// Spoken Margins get the full moment: lead-in, the Margin inline, then the item's other spoken Margins as
    /// playback reaches them. Written Margins keep playing from the anchor. A Margin anchored only by text position
    /// (an article read aloud on the device, #1577) counts its lead-in in narration time; see `MarginMomentClock`.
    func startMarginMomentIfSpoken(_ interjection: Interjection, store: SQLiteSessionStore) {
        guard interjection.isSpokenItemMargin else { return }
        let clock: MarginMomentClock = snapshot.targetType == TargetType.itemTextTTS.rawValue ? .liveNarration : .media
        let spoken = spokenItemMargins(itemId: interjection.itemId, store: store)
        let text = clock.isNarratedText ? ((try? store.loadItem(id: interjection.itemId))?.text ?? "") : ""
        guard let anchors = MarginMomentPlanner.anchors(
            played: interjection, among: spoken, clock: clock, targetMediaTimeMs: snapshot.currentMediaTimeMs, text: text
        ) else { return }
        var voiceURLs: [String: URL] = [:]
        for margin in spoken + [interjection] {
            if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }
        }
        startMarginMoment(
            sequence: MarginMomentSequence(
                itemId: interjection.itemId,
                target: anchors.target,
                otherMargins: anchors.others,
                tickAdvanceLimitMs: clock.tickAdvanceLimitMs
            ),
            voiceURLs: voiceURLs,
            title: "Your Margin",
            isApproximate: false,
            clock: clock
        )
    }

    /// The listener's spoken Margins on the item, from every session, in no particular order.
    func inlineSpokenMargins(itemId: String, store: SQLiteSessionStore) -> [Interjection] {
        spokenItemMargins(itemId: itemId, store: store).filter(\.isInlineSpokenMargin)
    }

    /// The same, including those anchored only by a text position.
    func spokenItemMargins(itemId: String, store: SQLiteSessionStore) -> [Interjection] {
        let sessions: [Session] = (try? store.loadSessions(itemId: itemId)) ?? []
        return sessions
            .flatMap { session -> [Interjection] in (try? store.loadInterjections(sessionId: session.id)) ?? [] }
            .filter(\.isSpokenItemMargin)
    }

    /// Where the source stands on the moment's own clock: its media time, or the narration time of the text
    /// being read. The coming-up card counts down on this.
    var marginMomentPositionMs: Int? { marginMomentPositionMs(in: snapshot) }

    func marginMomentPositionMs(in current: SessionSnapshot) -> Int? {
        guard marginMomentClock.isNarratedText else { return current.currentMediaTimeMs }
        return current.currentTextStart.map(marginMomentClock.position(forTextOffset:))
    }

    /// The conductor's seek (to the Margin on "Play it now", or back to the start of the lead-in).
    func seekMarginMomentSource(toPosition position: Int) {
        if marginMomentClock.isNarratedText {
            seekText(toCharOffset: marginMomentClock.textOffset(forPosition: position))
        } else {
            seekMedia(toMediaTimeMs: position)
        }
    }

    /// Starts the moment's lead-in: the source seeks back to the lead-in's start. An article read aloud goes back
    /// to the start of the sentence nearest thirty seconds before the Margin, so speech doesn't begin mid-sentence.
    func startMarginMomentLeadIn(_ conductor: MarginMomentConductor, target: MarginMomentAnchor, itemId: String, resuming: Bool) {
        let clock = marginMomentClock
        if resuming {
            conductor.startListening(atMediaTimeMs: snapshot.currentMediaTimeMs)
        } else if clock.isNarratedText {
            let text = (try? store?.loadItem(id: itemId))?.text ?? ""
            let start = clock.leadInStartOffset(forTargetPosition: target.mediaTimeMs, in: text)
            seekText(toCharOffset: start)
            conductor.startListening(atMediaTimeMs: clock.position(forTextOffset: start))
        } else {
            conductor.start()
        }
    }
}
