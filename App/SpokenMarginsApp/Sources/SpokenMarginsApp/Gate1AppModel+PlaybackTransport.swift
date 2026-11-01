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

/// Playback transport: skips, seeks and playback rate (#1022).
extension Gate1AppModel {
    func skipBack() {
        marginMomentConductor?.sourceMoved() // a skip over a Margin doesn't play it (#1646)
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.skipBack(unit: skipUnitForCurrentTarget())
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItemAfterTransport()
            reportSuccess("Skipped back.")
        }
    }

    func skipBackMedia() {
        marginMomentConductor?.sourceMoved() // a skip over a Margin doesn't play it (#1646)
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipBack(unit: mediaSkipUnit(seconds: mediaSkipBackSeconds))
            refreshSelectedItemAfterTransport()
        }
    }

    func skipForward() {
        marginMomentConductor?.sourceMoved() // a skip over a Margin doesn't play it (#1646)
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            let unit = skipUnitForCurrentTarget()
            snapshot = try engine.skipForward(unit: unit)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItemAfterTransport()
            reportSuccess("Skipped forward.")
        }
    }

    func skipForwardMedia() {
        marginMomentConductor?.sourceMoved() // a skip over a Margin doesn't play it (#1646)
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipForward(unit: mediaSkipUnit(seconds: mediaSkipForwardSeconds))
            refreshSelectedItemAfterTransport()
        }
    }

    /// The streaming speech anchor catches up before a compact control (Lock Screen, headphones, Watch, CarPlay) runs.
    func synchronizeSpeechAnchorForCompactCommand(_ command: CompactControlCommand, canonicalTransport: Bool) {
        if command == .beginInterjection || canonicalTransport { synchronizeStreamingSpeechAnchorIfNeeded() }
    }

    func mediaSkipSettingsChanged() {
        mediaSkipBackSeconds = MediaSkipRule.validated(mediaSkipBackSeconds)
        mediaSkipForwardSeconds = MediaSkipRule.validated(mediaSkipForwardSeconds)
        UserDefaults.standard.set(mediaSkipBackSeconds, forKey: "mediaSkipBackSeconds")
        UserDefaults.standard.set(mediaSkipForwardSeconds, forKey: "mediaSkipForwardSeconds")
        mediaPlaybackClient?.setPreferredSkipIntervals(
            backSeconds: mediaSkipBackSeconds,
            forwardSeconds: mediaSkipForwardSeconds
        )
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
    }

    func setMediaPlaybackRate(_ rate: Double) {
        guard !rejectNavigationOrSessionMutationWhileRecording("set_media_playback_rate") else { return }
        let clamped = SpeechRateRule.quarterStepMultiplier(rate)
        mediaPlaybackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "mediaPlaybackRate")
        if var bridge = snapshot.skimBridgeState {
            if bridge.status == .playing {
                skimBridge.setTransportRate(forPlaybackRate: clamped)
            }
            snapshot.playbackRate = clamped
            bridge.status = snapshot.skimBridgeState?.status ?? bridge.status
            snapshot.skimBridgeState = bridge
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
            return
        }
        run { engine in
            snapshot = try engine.setPlaybackRate(clamped)
            refreshSelectedItemAfterTransport()
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
        }
    }

    /// Seeks the source player, or records the destination when a restored paused session
    /// has no player yet; the next playback start then opens the source there.
    func seekOrStageMedia(_ engine: SessionEngine, toMediaTimeMs mediaTimeMs: Int) throws -> SessionSnapshot {
        do {
            return try engine.seekMedia(toMediaTimeMs: mediaTimeMs)
        } catch SessionKitError.invalidCommandForState(let reason)
            where reason == "media_seek_player_unavailable" && engine.snapshot.status == .paused {
            return try engine.stagePausedMediaPosition(toMediaTimeMs: mediaTimeMs)
        }
    }

    @discardableResult
    func seekMedia(toMediaTimeMs mediaTimeMs: Int) -> Bool {
        marginMomentConductor?.sourceMoved()
        recordDeveloperDiagnostic("seek.media.request", ["timeMs": String(mediaTimeMs)])
        restoreSkimOriginBeforeCanonicalTransport()
        return run { engine in
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: mediaTimeMs)
            recordMediaSeekEvidence(from: engine)
            refreshSelectedItemAfterTransport()
        }
    }

    func cyclePlaybackRate() {
        guard !rejectNavigationOrSessionMutationWhileRecording("cycle_playback_rate") else { return }
        let current = isMediaPlaybackSnapshot ? mediaPlaybackRate : speechPlaybackRateMultiplier
        let next = Self.nextPlaybackRate(after: current)
        if isMediaPlaybackSnapshot {
            setMediaPlaybackRate(next)
        } else {
            speechRate = next * 0.5
            playbackSpeechRateChanged()
        }
    }

    nonisolated static func nextPlaybackRate(after current: Double) -> Double {
        SpeechRateRule.next(after: current)
    }

    func recordMediaSeekEvidence(from engine: SessionEngine) {
        guard let request = engine.lastMediaSeekRequest,
              let resolution = engine.lastMediaSeekResolution else { return }
        let outcome: String
        switch resolution {
        case .pending:
            outcome = "pending"
        case .accepted(let mediaTimeMs):
            outcome = "accepted:\(mediaTimeMs)"
        case .failed(let actualMediaTimeMs, let reason):
            outcome = "failed:\(actualMediaTimeMs.map(String.init) ?? "unknown"):\(reason)"
        }
        let evidence = "id:\(request.id),requested:\(request.requestedMediaTimeMs),outcome:\(outcome)"
        if diagnostics["mediaSeek"] != evidence {
            recordDeveloperDiagnostic("seek.media.result", ["id": String(request.id),
                "requested": String(request.requestedMediaTimeMs), "outcome": outcome])
        }
        diagnostics["mediaSeek"] = evidence
    }

    @discardableResult
    func seekText(toCharOffset charOffset: Int) -> Bool {
        marginMomentConductor?.sourceMoved()
        restoreSkimOriginBeforeCanonicalTransport() // a tap in the reader ends a Skim summary, as a media seek does (#1471)
        if playingImportedCommentary != nil, heldMarginVoice?.kind != .shared { stopImportedCommentaryPlayback(resumeSource: false) } // Add a Margin holds the voice and moves the source under it (#1672)
        recordDeveloperDiagnostic("seek.text.request", ["offset": String(charOffset)])
        synchronizeStreamingSpeechAnchorIfNeeded()
        return run { engine in
            snapshot = try engine.seekText(toCharOffset: charOffset)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItemAfterTransport()
        }
    }

    func playbackSpeechRateChanged() {
        guard !rejectNavigationOrSessionMutationWhileRecording("set_speech_playback_rate") else { return }
        saveSpeechSettings()
        guard !isMediaPlaybackSnapshot else {
            return
        }
        if ttsVoiceSelection.isOnDeviceVoice, audioPlaybackClientOverride == nil {
            applySupertonicPlaybackRate()
            return
        }
        run { engine in
            snapshot = try engine.updateSpeechPlaybackSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            refreshSelectedItemAfterTransport()
            diagnostics["speechRateApplied"] = String(format: "%.2f", speechRate)
        }
    }

    func applySupertonicPlaybackRate() {
        let transportRate = speechPlaybackRateMultiplier
        do {
            try speechPlaybackClient?.configureSpeechSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            if let engine, hasActiveSession {
                snapshot = try engine.setPlaybackRate(transportRate)
                refreshSelectedItemAfterTransport()
            }
            diagnostics["speechRateApplied"] = String(format: "%.2f", transportRate)
        } catch {
            reportFailure(error, context: "Speaking rate update failed")
        }
    }

    func applyPreferredPlaybackRate(
        to started: SessionSnapshot,
        engine: SessionEngine
    ) throws -> SessionSnapshot {
        switch started.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return started.playbackRate == mediaPlaybackRate
                ? started
                : try engine.setPlaybackRate(mediaPlaybackRate)
        case TargetType.itemTextTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue where ttsVoiceSelection.isOnDeviceVoice:
            let transportRate = speechPlaybackRateMultiplier
            return started.playbackRate == transportRate
                ? started
                : try engine.setPlaybackRate(transportRate)
        default:
            return started
        }
    }
}
