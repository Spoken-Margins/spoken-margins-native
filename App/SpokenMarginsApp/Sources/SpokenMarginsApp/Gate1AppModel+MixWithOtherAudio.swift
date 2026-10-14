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

/// Mixing Spoken Margins with other apps' audio (#1022).
extension Gate1AppModel {
    func mixWithOtherAudioAvailabilityChanged() {
        UserDefaults.standard.set(
            showsMixWithOtherAudioOption,
            forKey: Self.showsMixWithOtherAudioOptionKey
        )
        if !showsMixWithOtherAudioOption, mixesWithOtherAudio {
            setMixesWithOtherAudio(false)
        }
        diagnostics["mixWithOtherAudioAvailable"] = showsMixWithOtherAudioOption ? "true" : "false"
    }

    func setMixesWithOtherAudio(_ enabled: Bool) {
        guard playingImportedCommentary == nil else {
            reportWarning("Return to Source before changing audio mixing.")
            return
        }
        guard enabled != mixesWithOtherAudio else { return }
        guard !enabled || showsMixWithOtherAudioOption else {
            reportFailure("Enable Mix with Other Audio in Settings before using it for a listening session.")
            return
        }
        let audio = sessionAudioPlaybackClient ?? audioPlaybackClientOverride
        do {
            if enabled {
                gate2CompactControls.setNowPlayingEnabled(false)
                audio?.setRemoteCommandHandlingEnabled(false)
                try audio?.setMixesWithOtherAudio(true)
                try audio?.setPlaybackVolume(Float(mixedPlaybackVolume))
            } else {
                try audio?.setLowersBackgroundAudio(false)
                try audio?.setMixesWithOtherAudio(false)
                try audio?.setPlaybackVolume(1)
                audio?.setRemoteCommandHandlingEnabled(true)
                gate2CompactControls.setNowPlayingEnabled(true)
            }
            mixesWithOtherAudio = enabled
            if !enabled { lowersBackgroundAudio = false }
            diagnostics["mixWithOtherAudio"] = enabled ? "enabled_for_session" : "disabled"
            diagnostics["spokenMarginsPlaybackVolume"] = String(format: "%.2f", enabled ? mixedPlaybackVolume : 1)
            updateGate2CompactState()
        } catch {
            if enabled {
                try? audio?.setMixesWithOtherAudio(false)
                try? audio?.setPlaybackVolume(1)
                audio?.setRemoteCommandHandlingEnabled(true)
                gate2CompactControls.setNowPlayingEnabled(true)
            } else {
                gate2CompactControls.setNowPlayingEnabled(false)
                audio?.setRemoteCommandHandlingEnabled(false)
                try? audio?.setMixesWithOtherAudio(true)
                try? audio?.setLowersBackgroundAudio(lowersBackgroundAudio)
                try? audio?.setPlaybackVolume(Float(mixedPlaybackVolume))
            }
            reportFailure(error, context: "Audio mixing update failed")
        }
    }

    func setLowersBackgroundAudio(_ enabled: Bool) {
        guard mixesWithOtherAudio, enabled != lowersBackgroundAudio else { return }
        let audio = sessionAudioPlaybackClient ?? audioPlaybackClientOverride
        do {
            try audio?.setLowersBackgroundAudio(enabled)
            lowersBackgroundAudio = enabled
        } catch {
            try? audio?.setLowersBackgroundAudio(lowersBackgroundAudio)
            reportFailure(error, context: "Background audio update failed")
        }
    }

    func mixedPlaybackVolumeChanged() {
        mixedPlaybackVolume = max(0, min(Self.mixedPlaybackVolumeMaximum, mixedPlaybackVolume))
        UserDefaults.standard.set(mixedPlaybackVolume, forKey: Self.mixedPlaybackVolumeKey)
        guard mixesWithOtherAudio else { return }
        do {
            try (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setPlaybackVolume(
                Float(mixedPlaybackVolume)
            )
            diagnostics["spokenMarginsPlaybackVolume"] = String(format: "%.2f", mixedPlaybackVolume)
        } catch {
            reportFailure(error, context: "Spoken Margins volume update failed")
        }
    }

    func resetMixWithOtherAudioForNewSession() {
        if mixesWithOtherAudio {
            setMixesWithOtherAudio(false)
        } else {
            sessionAudioPlaybackClient?.setRemoteCommandHandlingEnabled(true)
            gate2CompactControls.setNowPlayingEnabled(true)
        }
        diagnostics["mixWithOtherAudio"] = "default_off_for_session"
    }
}
