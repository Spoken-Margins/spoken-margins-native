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

/// Provider and speech settings, voice previews and rate wording (#961), moved unchanged out of the central model.
extension Gate1AppModel {
    func saveProviderSettings() {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Remote provider settings are disabled in this release.")
            return
        }
        sanitizeTTSMode()
        providerModel = fallbackProviderModel()
        UserDefaults.standard.set(providerModel, forKey: "providerModel")
        UserDefaults.standard.set(listeningMapModel, forKey: "listeningMapModel")
        UserDefaults.standard.set(summaryModel, forKey: "summaryModel")
        UserDefaults.standard.set(conversationModel, forKey: "conversationModel")
        UserDefaults.standard.set(skipUnit, forKey: "skipUnit")
        UserDefaults.standard.set(mediaSkipBackSeconds, forKey: "mediaSkipBackSeconds")
        UserDefaults.standard.set(mediaSkipForwardSeconds, forKey: "mediaSkipForwardSeconds")
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        let keychainStatus = KeychainStore.save(providerAPIKey, service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        guard keychainStatus == errSecSuccess else {
            diagnostics["keychainStatus"] = "save_failed:\(keychainStatus)"
            reportFailure("Provider settings were not saved because Keychain returned \(keychainStatus).")
            return
        }
        diagnostics["keychainStatus"] = providerAPIKey.isEmpty ? "empty" : "saved"
        cancelTextAudioPrewarmTasks()
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = providerModel
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["apiKeyConfigured"] = providerAPIKey.isEmpty ? "false" : "true"
        if rebuildEngineForCurrentSettings() {
            screen = .settings
            reportConfirmation("Provider settings saved.")
        }
    }

    func saveSpeechSettings() {
        sanitizeTTSMode()
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        cancelTextAudioPrewarmTasks()
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["speechTranscriptionEngine"] = systemSpeechTranscriptionEngineDescription()
    }

    func refreshSpeechVoiceOptions() {
        speechVoiceOptions = Self.availableSpeechVoiceOptions()
        diagnostics["speechVoiceCount"] = "\(speechVoiceOptions.count)"
        diagnostics["speechVoice"] = speechVoiceDescription
        let selected = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.supportsSpeechVoiceEnumeration {
            diagnostics["speechVoiceAvailability"] = "system_default_on_simulator"
        } else {
            diagnostics["speechVoiceAvailability"] = selected.isEmpty || speechVoiceOptions.contains(where: { $0.id == selected })
                ? "available"
                : "unavailable"
        }
    }

    func speechSettingsChanged() {
        let changed = sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        if changed {
            _ = rebuildEngineForCurrentSettings()
        } else if ttsVoiceSelection.isOnDeviceVoice, audioPlaybackClientOverride == nil {
            applySupertonicPlaybackRate()
        } else if !isMediaPlaybackSnapshot {
            run { engine in
                snapshot = try engine.updateSpeechPlaybackSettings(
                    voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                    rate: Float(speechRate)
                )
                refreshSelectedItem()
                diagnostics["speechSettingsApplied"] = snapshot.status.rawValue
                reportConfirmation("Speech settings saved.")
            }
        }
    }

    func ttsVoiceSelectionChanged() {
        if ttsVoiceSelection.isOnDeviceVoice, !hasAcceptedCurrentTerms {
            pendingTermsVoiceSelection = ttsVoiceSelection
            UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            diagnostics["termsGate"] = "presented_for_on_device_voice"
            statusMessage = "Review the Terms of Use to enable an on-device voice."
            return
        }
        stopSpeechPreviews() // a preview rendering in the old voice must not play under the new name (#2125)
        sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        if let engine {
            snapshot = (try? engine.stopPlayback()) ?? snapshot
            refreshSelectedItem()
        }
        _ = rebuildEngineForCurrentSettings()
        if ttsVoiceSelection.supertonicVoice == nil, let renderer = supertonicModel.reset(retiring: false) {
            Task { await renderer.unload() }
        }
        if ttsVoiceSelection == .system, let renderer = kittenRenderer {
            kittenRenderer = nil
            Task { await renderer.unload() }
        }
        reportSuccess("Voice changed to \(ttsVoiceSelection.displayName). Press play when you are ready.")
    }

    func previewSpokenContentVoice() {
        previewSpeech(label: "Spoken Content settings", mode: .spokenContent)
    }

    func previewAppVoice() {
        saveSpeechSettings()
        if ttsVoiceSelection == .kitten {
            previewKittenVoice()
            return
        }
        if let voice = ttsVoiceSelection.supertonicVoice {
            previewSupertonicVoice(voice)
            return
        }
        previewSpeech(
            label: "app voice and rate",
            mode: .appVoice(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
        )
    }

    private func previewSupertonicVoice(_ voice: SupertonicVoiceID) {
        guard hasAcceptedCurrentTerms else {
            pendingTermsVoiceSelection = ttsVoiceSelection.supertonicVoice == nil ? .james : ttsVoiceSelection
            UserDefaults.standard.set(pendingTermsVoiceSelection?.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            return
        }
        guard !isRenderingSupertonicPreview else { return }
        isRenderingSupertonicPreview = true
        statusMessage = "Preparing \(ttsVoiceSelection.displayName)…"
        let speed = Float(speechRate / 0.5)
        let request = supertonicPreviewRequest.begin(voice: voice)
        let preview = makeOnDeviceVoicePreview()
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await preview.render(
                    text: "Spoken Margins is ready to read with your selected on-device voice.", voice: voice, speed: speed)
                guard case let .rendered(result, supertonicMissing) = outcome else {
                    // Neither Supertonic nor Kitten can speak: the iOS voice is what reads now (#2219).
                    self.isRenderingSupertonicPreview = false
                    guard self.supertonicPreviewRequest.mayPlay(request, selectedVoice: self.ttsVoiceSelection.supertonicVoice, otherAudioActive: self.isOtherAudioActiveForPreview) else {
                        self.diagnostics["supertonicPreview"] = "dropped_stale"
                        return
                    }
                    self.diagnostics["supertonicPreview"] = "\(SupertonicModelNotDownloaded.fallbackCode):system_voice"
                    self.previewSpeech(label: "app voice and rate", mode: .appVoice(
                        voiceIdentifier: self.speechVoiceIdentifier.isEmpty ? nil : self.speechVoiceIdentifier,
                        rate: Float(self.speechRate)))
                    return
                }
                // Rendering takes seconds: play only if the listener hasn't moved on meanwhile (#2125).
                guard self.supertonicPreviewRequest.mayPlay(request, selectedVoice: self.ttsVoiceSelection.supertonicVoice, otherAudioActive: self.isOtherAudioActiveForPreview) else {
                    self.diagnostics["supertonicPreview"] = "dropped_stale"
                    await self.discardPreviewAudio(at: result.audioURL)
                    self.isRenderingSupertonicPreview = false
                    return
                }
                try self.playSupertonicPreview(url: result.audioURL)
                self.diagnostics["supertonicPreview"] = supertonicMissing ? SupertonicModelNotDownloaded.fallbackCode : "played"
                self.diagnostics["supertonicPreviewEngine"] = result.engine
                self.diagnostics["supertonicPreviewRenderSeconds"] = String(format: "%.3f", result.renderDuration)
                self.diagnostics["supertonicPreviewDurationSeconds"] = String(format: "%.3f", result.duration)
                self.diagnostics["supertonicSessionLoadCount"] = "\(result.sessionLoadCount)"
                self.reportSuccess(supertonicMissing
                    ? SupertonicModelNotDownloaded.previewMessage(voiceName: self.ttsVoiceSelection.displayName)
                    : "Playing \(self.ttsVoiceSelection.displayName).")
            } catch {
                self.reportFailure(error, context: "On-device voice preview failed")
            }
            self.isRenderingSupertonicPreview = false
        }
    }

    /// The sample's voice follows the files on the phone (#2219): Supertonic once downloaded, the bundled Kitten voice
    /// until then, as the player does.
    private func makeOnDeviceVoicePreview() -> OnDeviceVoicePreview {
        OnDeviceVoicePreview(
            isModelPresent: { [supertonicModel] in supertonicModel.isModelPresent },
            supertonic: { @MainActor [weak self] text, voice, speed in
                guard let self else { throw SupertonicNarrationError.missingAsset("Supertonic") }
                let renderer = try self.makeSupertonicRenderer()
                return try await renderer.render(text: text, voice: voice, speed: speed, synthesisSteps: 8)
            },
            kitten: { @MainActor [weak self] in
                guard let renderer = self?.makeKittenRenderer() else { return nil }
                return { text in try await renderer.render(text: text) }
            }
        )
    }

    /// Each renderer deletes only files it wrote, so asking both removes the sample whichever voice made it.
    func discardPreviewAudio(at url: URL) async {
        await supertonicRenderer?.discardGeneratedAudio(at: url)
        await kittenRenderer?.discardGeneratedAudio(at: url)
    }

    /// Narration, a Margin's voice, a recording or a microphone request: a voice preview must not play over any of them (#2125).
    var isOtherAudioActiveForPreview: Bool {
        snapshot.status.isPlaybackActive || snapshot.isRecording || isRequestingRecordingPermission
            || (marginVoicePlayer.ownMarginID != nil && !marginVoicePlayer.ownIsPaused)
            || (marginVoicePlayer.sharedMargin != nil && !marginVoicePlayer.sharedIsPaused)
    }

    func verifyCurrentTermsForOnDeviceVoice() throws {
        guard SpokenMarginsTerms.hasBundledText() else {
            throw SpokenMarginsTermsError.bundledTermsUnavailable
        }
        guard hasAcceptedCurrentTerms else {
            throw SpokenMarginsTermsError.acceptanceRequired
        }
    }

    func previewAssistiveTechnologyVoice() {
        previewSpeech(label: "assistive technology settings", mode: .assistiveTechnology)
    }

    func runtimeProfileChanged() {
        diagnostics["runtimeProfile"] = selectedProfileId
        if rebuildEngineForCurrentSettings() {
            reportSuccess("Runtime profile set to \(selectedProfileId).")
        }
    }

    func settingsValueChanged() {
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = fallbackProviderModel()
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
    }

    func probeProvider() {
        guard remoteProviderExperienceEnabled else {
            providerProbeStatus = "Disabled by release feature flag"
            reportFailure("Remote provider access is disabled in this release.")
            return
        }
        saveProviderSettings()
        providerProbeStatus = "Checking..."
        guard let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            providerProbeStatus = "Invalid URL"
            reportFailure("Invalid provider URL.")
            return
        }
        var request = URLRequest(url: url)
        if !providerAPIKey.isEmpty {
            request.setValue("Bearer \(providerAPIKey)", forHTTPHeaderField: "Authorization")
        }
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    providerProbeStatus = (200..<300).contains(status) ? "Reachable (\(status))" : "HTTP \(status)"
                    diagnostics["providerProbe"] = providerProbeStatus
                    reportSuccess("Provider probe completed: \(providerProbeStatus).")
                }
            } catch {
                await MainActor.run {
                    providerProbeStatus = "Failed: \(error.localizedDescription)"
                    reportFailure(error, context: "Provider probe failed")
                }
            }
        }
    }

    var speechVoiceDescription: String {
        if ttsVoiceSelection != .system {
            guard let voice = ttsVoiceSelection.supertonicVoice else { return ttsVoiceSelection.displayName }
            return "\(ttsVoiceSelection.displayName) (Supertonic \(voice.rawValue))"
        }
        guard !speechVoiceIdentifier.isEmpty else {
            return "System Spoken Content Voice (Siri falls back)"
        }
        if let voice = speechVoiceOptions.first(where: { $0.id == speechVoiceIdentifier }) {
            return "\(voice.name) (\(voice.language), \(voice.quality))"
        }
        return speechVoiceIdentifier
    }

    var speechRateDescription: String {
        if ttsVoiceSelection.supertonicVoice != nil {
            return String(format: "Supertonic %.2fx", speechPlaybackRateMultiplier)
        }
        if ttsVoiceSelection == .kitten {
            return String(format: "Kitten %.2fx", speechPlaybackRateMultiplier)
        }
        return String(format: "System %.2fx", speechPlaybackRateMultiplier)
    }

    var speechPlaybackRateMultiplier: Double {
        SpeechRateRule.quarterStepMultiplier(speechRate / 0.5)
    }

    var compactPlaybackRateDescription: String {
        if isMediaPlaybackSnapshot {
            return String(format: "%.2f×", mediaPlaybackRate)
        }
        return String(format: "%.2f×", speechPlaybackRateMultiplier)
    }

    var hasConfiguredProviderAPIKey: Bool {
        !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    #if canImport(AVFoundation)
    func stopSpeechPreviews() {
        supertonicPreviewRequest.cancel() // a preview still rendering must not start later (#2125)
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        supertonicPreviewPlayer?.stop()
    }

    func playSupertonicPreview(url: URL) throws {
        stopSpeechPreviews()
        if let priorURL = supertonicPreviewURL {
            Task { await discardPreviewAudio(at: priorURL) }
        }
        #if os(iOS)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        supertonicPreviewPlayer = try AVAudioPlayer(contentsOf: url)
        supertonicPreviewPlayer?.prepareToPlay()
        guard supertonicPreviewPlayer?.play() == true else {
            throw SupertonicNarrationError.unsafeAudio("preview_playback_failed")
        }
        supertonicPreviewURL = url
    }

    #else
    func stopSpeechPreviews() { supertonicPreviewRequest.cancel() }
    #endif
}
