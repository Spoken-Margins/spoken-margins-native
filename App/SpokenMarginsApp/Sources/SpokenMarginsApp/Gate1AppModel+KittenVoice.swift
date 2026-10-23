import Foundation
import SessionKit
import SessionKitSupertonic

/// Kitten (Jasper) as a reading voice the listener picks (#2226). It was the fallback for everyone without the
/// Supertonic download; now it can also be the choice. The player is the same one James and Lily use, held on the
/// bundled voice for the whole item (`makeSpeechPlaybackClient`), so this file holds only what is Kitten's own.
extension Gate1AppModel {
    #if canImport(AVFoundation)
    /// "Try App Voice" with Kitten picked: Kitten speaks the sample, from the files in the app. No Supertonic is
    /// asked for, so nothing here can start a download or fail for a missing model.
    func previewKittenVoice() {
        guard hasAcceptedCurrentTerms else {
            pendingTermsVoiceSelection = .kitten
            UserDefaults.standard.set(AppTTSVoiceSelection.kitten.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            return
        }
        guard !isRenderingSupertonicPreview else { return }
        isRenderingSupertonicPreview = true
        statusMessage = "Preparing \(ttsVoiceSelection.displayName)…"
        // The preview request tracks "still the latest, still this voice, nothing else playing" (#2125); it is keyed
        // by a Supertonic voice id, so Kitten uses one stand-in id for its token and for the voice it checks against.
        let request = supertonicPreviewRequest.begin(voice: Self.kittenPreviewTokenVoice)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRenderingSupertonicPreview = false }
            guard let renderer = self.makeKittenRenderer() else {
                self.diagnostics["supertonicPreview"] = "kitten_unavailable"
                self.reportFailure("Kitten's voice files could not be opened.")
                return
            }
            do {
                let result = try await renderer.render(
                    text: "Spoken Margins is ready to read with your selected on-device voice.")
                let stillKitten = self.ttsVoiceSelection == .kitten
                guard self.supertonicPreviewRequest.mayPlay(
                    request, selectedVoice: stillKitten ? Self.kittenPreviewTokenVoice : nil,
                    otherAudioActive: self.isOtherAudioActiveForPreview) else {
                    self.diagnostics["supertonicPreview"] = "dropped_stale"
                    await renderer.discardGeneratedAudio(at: result.audioURL)
                    return
                }
                try self.playSupertonicPreview(url: result.audioURL)
                self.diagnostics["supertonicPreview"] = "played"
                self.diagnostics["supertonicPreviewEngine"] = result.engine
                self.diagnostics["supertonicPreviewRenderSeconds"] = String(format: "%.3f", result.renderDuration)
                self.diagnostics["supertonicPreviewDurationSeconds"] = String(format: "%.3f", result.duration)
                self.reportSuccess("Playing \(self.ttsVoiceSelection.displayName).")
            } catch {
                self.reportFailure(error, context: "On-device voice preview failed")
            }
        }
    }

    private static let kittenPreviewTokenVoice = SupertonicVoiceID.m2
    #endif
}
