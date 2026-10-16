import Foundation
import SessionKit

/// The Margin voice that was playing when the listener recorded a Margin over it (#1672).
struct HeldMarginVoice: Equatable {
    enum Kind: Equatable { case moment, own, shared }
    let kind: Kind
    /// It was sounding, not paused by the listener, so it plays on after the save.
    let wasSounding: Bool
}

/// Pausing and recording over a Margin's voice, without losing it (#1672). A voice the listener pauses stays where it
/// stopped, and Add a Margin over a voice holds it the same way: it is paused and kept, the recording runs, and Save or
/// Cancel plays it on. The source stays paused at the Margin's place until the voice ends, and then follows as usual.
extension Gate1AppModel {
    var ownMarginVoiceIsPaused: Bool { marginVoicePlayer.ownIsPaused }

    /// Your own Margin, played from its detail, paused or played on in place. Nothing resumes the source.
    func setOwnMarginPaused(_ paused: Bool) {
        guard playingInterjectionAudioId != nil else { return }
        do {
            try marginVoicePlayer.setOwnPaused(paused)
        } catch {
            reportFailure(error, context: "Margin resume failed")
        }
    }

    /// Your own Margin's voice has the transport: Play and Pause act on it, as on a moment's voice or a shared
    /// Margin's. The source resumed over it (Lock Screen, headphones) keeps the transport, as it did (#1538).
    var ownMarginVoiceHasTransport: Bool {
        playingInterjectionAudioId != nil && !snapshot.status.isPlaybackActive
    }

    /// The voice `handOffPlayingMarginToRecording` paused and kept, while it is still there to play on.
    var heldMarginVoice: HeldMarginVoice? {
        guard let held = marginVoiceHeldForRecording else { return nil }
        let stillHeld: Bool
        switch held.kind {
        case .moment: stillHeld = marginMomentConductor.map { $0.isPlayingVoice && $0.isVoicePaused } ?? false
        case .own: stillHeld = playingInterjectionAudioId != nil && ownMarginVoiceIsPaused
        case .shared: stillHeld = playingImportedCommentary != nil && importedCommentaryIsPaused
        }
        return stillHeld ? held : nil
    }

    /// A Margin is recording over a held voice, or waiting on the microphone to. Play and Pause have nothing to act on
    /// until it is saved or cancelled.
    var marginVoiceIsHeldForRecording: Bool {
        (snapshot.isRecording || isRequestingRecordingPermission) && heldMarginVoice != nil
    }

    /// The recording is over (saved, cancelled, or never started): the voice it held plays on from where it stopped.
    /// One the listener had paused themselves stays paused, for Play.
    func resumeHeldMarginVoice(_ held: HeldMarginVoice?) {
        marginVoiceHeldForRecording = nil
        guard let held else { return }
        if held.kind == .shared { setSharedVoiceTransport(heldForRecording: false) }
        guard held.wasSounding else { return }
        switch held.kind {
        case .moment: marginMomentConductor?.setVoicePaused(false)
        case .own: setOwnMarginPaused(false)
        case .shared: setImportedCommentaryPaused(false)
        }
    }

    /// The system transport while a shared voice is held for a recording: it belongs to the recording, so a headphone
    /// click or Lock Screen Play/Pause saves the Margin (#1030) as it did when Add a Margin stopped the voice. The
    /// voice takes it back when it plays on. `stopInterjectionAudioPlayback` gives the same back when the voice is let go.
    private func setSharedVoiceTransport(heldForRecording: Bool) {
        guard !mixesWithOtherAudio else { return }
        if heldForRecording { marginVoicePlayer.endRemoteControls() } else { marginVoicePlayer.installSharedRemoteControls() }
        (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(heldForRecording)
        gate2CompactControls.setNowPlayingEnabled(heldForRecording)
    }

    /// #866: Add Margin while a Margin plays records straight away. The voice pauses where it is (#1672) and the source
    /// moves to the playing Margin's place so the new Margin is anchored there. False when that move failed: nothing
    /// records, rather than recording at the wrong place.
    func handOffPlayingMarginToRecording() -> Bool {
        let prior = heldMarginVoice // a second tap before recording starts finds the voice already held; a marker left by an earlier recording doesn't count
        marginVoiceHeldForRecording = nil
        func held(_ kind: HeldMarginVoice.Kind, paused: Bool) -> HeldMarginVoice {
            HeldMarginVoice(kind: kind, wasSounding: isRequestingRecordingPermission && prior?.kind == kind ? prior?.wasSounding ?? !paused : !paused)
        }
        let handoff: MarginCaptureHandoff
        if let prompt = playingImportedCommentary {
            handoff = MarginCaptureHandoff(sharedMargin: prompt.interjection, itemId: prompt.layer.itemId)
            sharedMarginOffers.markAnnounced(prompt.id) // the rejoin mustn't offer it again
            if importedCommentaryPhase.isFailed {
                stopImportedCommentaryPlayback(resumeSource: false) // nothing sounds to keep
            } else {
                marginVoiceHeldForRecording = held(.shared, paused: importedCommentaryIsPaused)
                setImportedCommentaryPaused(true)
                setSharedVoiceTransport(heldForRecording: true)
            }
        } else if let conductor = marginMomentConductor, conductor.isPlayingVoice {
            handoff = MarginCaptureHandoff(moment: conductor.sequence)
            marginVoiceHeldForRecording = held(.moment, paused: conductor.isVoicePaused)
            conductor.setVoicePaused(true)
        } else if let playingID = playingInterjectionAudioId {
            // Your own Margin heard from its detail: it sits where it was recorded.
            let margin = playingInterjectionAudioSessionID.flatMap { try? store?.loadInterjections(sessionId: $0) }?.first { $0.id == playingID }
            handoff = margin.map { MarginCaptureHandoff(localMargin: $0) } ?? MarginCaptureHandoff(itemId: nil, place: nil)
            if ownMarginVoiceHasTransport {
                marginVoiceHeldForRecording = held(.own, paused: ownMarginVoiceIsPaused)
                setOwnMarginPaused(true)
            } else {
                stopInterjectionAudioPlayback() // the source was resumed over it (#1538): Save and Cancel put the source back, not the Margin
            }
        } else {
            return true
        }
        let move = handoff.sourceMove(from: snapshot)
        diagnostics["marginCaptureHandoff"] = String(describing: move)
        let moved: Bool
        switch move {
        case .stay: return true
        case .seekMedia(let ms): moved = seekMedia(toMediaTimeMs: ms)
        case .seekText(let charOffset): moved = seekText(toCharOffset: charOffset)
        }
        if !moved {
            resumeHeldMarginVoice(heldMarginVoice) // nothing records, so the Margin plays on
            reportFailure("Couldn't go back to that Margin's place, so no Margin was started. Tap Add Margin again to record where the source is.")
        }
        return moved
    }
}
