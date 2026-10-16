import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSupertonic

extension Gate1AppModel {
    func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        if let audioPlaybackClientOverride {
            diagnostics["sessionTTS"] = "Test audio override"
            try configureAudioPlaybackPolicy(audioPlaybackClientOverride)
            sessionAudioPlaybackClient = audioPlaybackClientOverride
            return audioPlaybackClientOverride
        }
        sanitizeTTSMode()
        let speech = try makeSpeechPlaybackClient()
        speechPlaybackClient = speech
        let routed = RoutedAudioPlaybackClient(
            speech: speech,
            media: makeMediaPlaybackClient()
        )
        try configureAudioPlaybackPolicy(routed)
        sessionAudioPlaybackClient = routed
        streamingSpeechQueue.configureSpeechClient(routed)
        return routed
    }

    private func configureAudioPlaybackPolicy(_ audio: AudioPlaybackClient) throws {
        try audio.setMixesWithOtherAudio(mixesWithOtherAudio)
        try audio.setLowersBackgroundAudio(mixesWithOtherAudio && lowersBackgroundAudio)
        try audio.setPlaybackVolume(mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1)
        audio.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
    }

    private func makeSpeechPlaybackClient() throws -> AudioPlaybackClient {
        let selectedVoice = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let appleVoiceIsAvailable = !Self.supportsSpeechVoiceEnumeration
            || selectedVoice.isEmpty
            || Self.availableSpeechVoiceOptions().contains(where: { $0.id == selectedVoice })
        if ttsVoiceSelection == .system, !appleVoiceIsAvailable {
            diagnostics["speechVoiceAvailability"] = "unavailable"
            throw SessionKitError.persistenceFailed("selected_speech_voice_unavailable")
        }
        if let voice = ttsVoiceSelection.supertonicVoice {
            let renderer = try makeSupertonicRenderer()
            let supportDirectory = try applicationSupportDirectory()
            guard let store else { throw SessionKitError.persistenceFailed("prepared_audio_store_unavailable") }
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                throw SupertonicNarrationError.missingAsset("Supertonic")
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signatureTask = Task.detached(priority: .userInitiated) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }
            let coordinator = PreparedAudioCoordinator(
                repository: store,
                rootDirectory: supportDirectory.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            let hooks = PreparedSpeechHooks(store: store, coordinator: coordinator, signatureTask: signatureTask) // #336
            Task { [weak self] in
                guard let signature = try? await signatureTask.value,
                      let self, self.ttsVoiceSelection.supertonicVoice == voice else { return }
                self.currentSupertonicRenderSignature = signature
            }
            let diskCache: RenderedSpeechDiskCache
            if let renderedSpeechDiskCache {
                renderedSpeechDiskCache.setLimitBytes(renderedSpeechCacheLimitMB * 1024 * 1024)
                diskCache = renderedSpeechDiskCache
            } else {
                let created = try RenderedSpeechDiskCache(
                    directory: supportDirectory.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory),
                    limitBytes: renderedSpeechCacheLimitMB * 1024 * 1024
                )
                renderedSpeechDiskCache = created
                diskCache = created
            }
            diagnostics["sessionTTS"] = "Supertonic 3 INT8 \(voice.rawValue)"
            diagnostics["renderedSpeechCacheLimitMB"] = "\(renderedSpeechCacheLimitMB)"
            diagnostics["renderedSpeechCacheBytes"] = "\(diskCache.sizeBytes)"
            return SupertonicSpeechPlaybackClient(
                renderer: supertonicOutputGuard(wrapping: renderer, systemVoice: selectedVoice),
                voice: voice,
                speed: Float(speechRate / 0.5),
                fallbackVoiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
                fallbackRate: Float(speechRate),
                diskCache: diskCache,
                preparedAudioDirectory: supportDirectory.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory),
                voiceChangeCue: { [chime = NarrationVoiceChangeChime()] in _ = chime.play() },
                pressureRenderer: makeKittenRenderer(),
                interruptionHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleSpeechPlaybackInterruption(event)
                    }
                },
                onGenerationStateChange: { [weak self] state, stopReason in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationState(state, stopReason: stopReason)
                    }
                },
                onGenerationProgress: { [weak self] progress in Task { @MainActor [weak self] in self?.updateOnDeviceSpeechGenerationProgress(progress) } },
                onChunkHandOverGap: { [weak self] gap in Task { @MainActor [weak self] in self?.runtimeDiagnostics.recordChunkHandOverGap(gap) } },
                onPreparationPlan: { await hooks.planned(itemId: $0, articleIdentity: $1, plan: $2) },
                onPreparedChunk: { await hooks.rendered(itemId: $0, articleIdentity: $1, plan: $2, audioURL: $3, durationMs: $4, engine: $5) },
                articleText: { hooks.articleText(itemId: $0) },
                preparedChunkLookup: { await hooks.lookup(itemId: $0, articleIdentity: $1, plan: $2) },
                bundledVoiceChunkLookup: { await hooks.lookup(itemId: $0, articleIdentity: $1, plan: $2, engine: KittenNarrationRenderer.engine) },
                onPreparedAudio: { [weak self] itemId, prepared in
                    Task { @MainActor [weak self] in
                        guard let signature = try? await signatureTask.value, let self else { return }
                        guard let store = self.store,
                              let item = try? store.loadItem(id: itemId),
                              let canonical = prepared.canonicalized(toItemText: item.text) else {
                            self.diagnostics["supertonicPreparedCanonicalization:\(itemId)"] = "source_mismatch"
                            return
                        }
                        let attached = self.attachPreparedTextAudio(
                            canonical,
                            itemId: itemId,
                            preparedStatus: "ready",
                            diagnosticStatus: "supertonic_full_ready",
                            replaceActivePlayback: false
                        )
                        if attached {
                            try? await coordinator.complete(itemId: itemId, signature: signature, prepared: canonical)
                        }
                        if attached, let renderer = self.supertonicRenderer {
                            Task { [weak self] in
                                await renderer.unload(removingGeneratedAudio: false)
                                await MainActor.run { [weak self] in
                                    self?.diagnostics["supertonicRuntimeAfterFullAudio"] = "unloaded"
                                }
                            }
                        }
                    }
                },
                onFallback: { [weak self] reason, offset, itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.suppressAudioPreparation(itemId: itemId)
                        if let coordinator = self.preparedAudioCoordinator,
                           let signature = self.currentSupertonicRenderSignature {
                            try? await coordinator.stop(itemId: itemId, signature: signature)
                        }
                        // I14: the reason is shown and logged with the power state beside it,
                        // so a device report shows whether charging or Low Power Mode coincided.
                        let conditions = self.currentResourceConditions()
                        let fallbackReason = SpeechFallbackReason(
                            supertonicCode: reason,
                            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
                        )
                        self.recordSupertonicFallbackEvent(code: reason, reason: fallbackReason, conditions: conditions, offset: offset)
                        self.speechFallbackReason = fallbackReason
                        self.diagnostics["supertonicFallback"] = reason
                        self.diagnostics["supertonicFallbackReason"] = fallbackReason.rawValue
                        self.diagnostics["supertonicFallbackConditions"] = conditions.logDescription
                        self.diagnostics["supertonicFallbackOffset"] = "\(offset)"
                        let message = fallbackReason.listenerExplanation
                        self.statusMessage = message
                        self.presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
                    }
                },
                onRestore: { [weak self] itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.speechFallbackReason = nil
                        self.allowAudioPreparation(itemId: itemId)
                        self.diagnostics["supertonicFallbackRestored"] = itemId
                    }
                },
                onBundledVoice: { [weak self] block, offset, _ in
                    Task { @MainActor [weak self] in self?.reportBundledVoiceTookOver(block: block, offset: offset) }
                },
                onStall: { [weak self] kind, fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic(kind, fields) } },
                onSystemPause: { [weak self] kind, fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic(kind, fields) } },
                onResumeDecision: { [weak self] fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic("supertonic.resume", fields) } },
                onRenderPace: { [weak self] summary in Task { @MainActor [weak self] in self?.diagnostics["onDeviceRenderPace"] = summary } },
                handOverHold: handOverBackgroundHold,
                interruptionHold: makeInterruptionBackgroundHold(),
                applicationIsActive: SupertonicSpeechPlaybackClient.isApplicationActive,
                applicationIsInBackground: SupertonicSpeechPlaybackClient.isApplicationInBackground,
                onBackgroundSeams: { [weak self] summary in Task { @MainActor [weak self] in self?.diagnostics["backgroundSeams"] = summary } }
            )
        }
        diagnostics["sessionTTS"] = "System speech"
        return SystemSpeechPlaybackClient(
            voiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
            speechRate: Float(speechRate)
        )
    }

    func makeSupertonicRenderer() throws -> SupertonicNarrationRenderer {
        try verifyCurrentTermsForOnDeviceVoice()
        if let supertonicRenderer { return supertonicRenderer }
        guard let resourceRoot = Bundle.main.resourceURL?.appending(
            path: "Supertonic",
            directoryHint: .isDirectory
        ) else {
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: resourceRoot),
            outputDirectory: cachesDirectory.appending(path: "SupertonicPlayback", directoryHint: .isDirectory),
            governor: .app
        )
        supertonicRenderer = renderer
        return renderer
    }

    /// Unloads both narration voices' sessions: Supertonic and the bundled Kitten fallback (#849).
    func unloadNarrationRenderers(removingGeneratedAudio: Bool = true) {
        if let renderer = supertonicRenderer {
            Task { await renderer.unload(removingGeneratedAudio: removingGeneratedAudio) }
        }
        if let renderer = kittenRenderer {
            Task { await renderer.unload(removingGeneratedAudio: removingGeneratedAudio) }
        }
    }

    /// I14 for the bundled Kitten voice (#849 audit): the listener sees why the voice changed, and the event is logged
    /// with the power state beside it. Preparation is left alone: Supertonic picks up again at the next play.
    /// `block` is what refused Supertonic when the bundled voice took over, so the notice names that cause even if the
    /// condition has cleared by the time the passage plays; the power state logged beside it is the current one.
    func reportBundledVoiceTookOver(block: SpeechFallbackReason?, offset: Int) {
        let code = "supertonic_resource_pressure"
        let conditions = currentResourceConditions()
        let reason = SpeechFallbackReason(supertonicCode: code, resourceBlock: block)
        recordSupertonicFallbackEvent(code: "\(code):\(KittenNarrationRenderer.engine)", reason: reason,
                                      conditions: conditions, offset: offset)
        diagnostics["supertonicFallback"] = "\(code):\(KittenNarrationRenderer.engine)"
        diagnostics["supertonicFallbackReason"] = reason.rawValue
        diagnostics["supertonicFallbackConditions"] = conditions.logDescription
        diagnostics["supertonicFallbackOffset"] = "\(offset)"
        let message = reason.bundledVoiceExplanation
        statusMessage = message
        presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
    }

    /// The bundled Kitten voice that takes over when Supertonic isn't allowed (#849). nil when its files can't be
    /// opened: the iOS voice covers the passage then, as before.
    func makeKittenRenderer() -> KittenNarrationRenderer? {
        if let kittenRenderer { return kittenRenderer }
        guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Kitten", directoryHint: .isDirectory),
              let cachesDirectory = try? FileManager.default.url(
                  for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
              let renderer = try? KittenNarrationRenderer(
                  assets: KittenAssetLocation(rootURL: resourceRoot),
                  outputDirectory: cachesDirectory.appending(path: "KittenPlayback", directoryHint: .isDirectory),
                  // One thread: Kitten runs only on a hot or pressed phone, and two threads cost about twice the CPU for
                  // 15% more speed, which the background CPU limit then takes back as rest (#1679).
                  threads: 1, governor: .app)
        else {
            diagnostics["kittenFallbackVoice"] = "unavailable"
            return nil
        }
        kittenRenderer = renderer
        return renderer
    }

    /// #240: chunks that fail the output check are read by the iOS voice; diagnostics say so.
    func supertonicOutputGuard(wrapping renderer: SupertonicRendering, systemVoice: String) -> SupertonicOutputGuard {
        let voice = systemVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        return SupertonicOutputGuard(wrapping: renderer, systemVoiceIdentifier: voice.isEmpty ? nil : voice) { [weak self] summary in
            Task { @MainActor [weak self] in self?.diagnostics["supertonicOutputCheck"] = summary }
        }
    }

    /// Background time while an audio interruption waits to end, one per player, watching for the other audio to
    /// stop because iOS doesn't report the end of a message announcement (#1434).
    private func makeInterruptionBackgroundHold() -> InterruptionBackgroundHold {
        #if canImport(AVFoundation) && os(iOS)
        let otherAudioWatch: InterruptionBackgroundHold.OtherAudioWatch? = .audioSession
        #else
        let otherAudioWatch: InterruptionBackgroundHold.OtherAudioWatch? = nil
        #endif
        return InterruptionBackgroundHold(
            begin: NarrationStartupBackgroundTime.begin,
            record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
            otherAudioWatch: otherAudioWatch
        )
    }

    private func makeMediaPlaybackClient() -> AudioPlaybackClient {
        let client = AVPlayerStreamPlaybackClient(
            preferredSkipBackSeconds: mediaSkipBackSeconds,
            preferredSkipForwardSeconds: mediaSkipForwardSeconds,
            interruptionHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleMediaPlaybackInterruption(event)
                }
            },
            interruptionHold: makeInterruptionBackgroundHold()
        ) { [weak self] command, mediaTimeMs, playbackRate in
            Task { @MainActor [weak self] in
                self?.syncPlaybackProgressForLifecycle()
                self?.dispatchGate2CompactCommand(
                    command,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: "now_playing"
                )
            }
        }
        client.playbackStartTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #160: resume after a spoken Margin on a stream took 2.6-9.3 s; this shows where the time goes.
                self?.recordDeveloperDiagnostic("media.start", fields)
            }
        }
        client.heardSourceWindowHandler = { [weak self] window in
            Task { @MainActor [weak self] in self?.handleHeardSourceWindow(window) }
        }
        client.playbackStallTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #166: the clock froze on a stream while the app showed "playing"; this records the player's state.
                self?.recordDeveloperDiagnostic(fields["event"] == "seek_abandoned" ? "media.seek_abandoned" : "media.stall", fields)
            }
        }
        #if canImport(AVFoundation) && canImport(ShazamKit)
        client.postResumePodcastEvidenceHandler = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePostResumePodcastEvidence(result)
            }
        }
        #endif
        mediaPlaybackClient = client
        return client
    }
}
