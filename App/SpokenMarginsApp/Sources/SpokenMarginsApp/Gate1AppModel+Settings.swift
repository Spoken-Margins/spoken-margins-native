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

enum AIDataSharingConsent: String {
    case unknown
    case grantedV1
    case declined
}

struct SpeechVoiceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

enum AppTTSVoiceSelection: String, CaseIterable, Identifiable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .james: "James"
        case .lily: "Lily"
        case .system: "iOS System Voice"
        }
    }

    var detail: String {
        switch self {
        case .james: "Deep, calm · M2"
        case .lily: "Bright, cheerful · F2"
        case .system: "Uses the selected voice installed in iOS"
        }
    }

    var supertonicVoice: SupertonicVoiceID? {
        switch self {
        case .james: .m2
        case .lily: .f2
        case .system: nil
        }
    }
}

struct PiperVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let modelURL: URL
    let configURL: URL?

    var displayName: String {
        language.isEmpty ? name : "\(name) · \(language)"
    }
}


private enum AppSpeechPreviewMode {
    case spokenContent
    case appVoice(voiceIdentifier: String?, rate: Float)
    case assistiveTechnology
}

#if canImport(AVFoundation)
private func voiceQualityName(_ voice: AVSpeechSynthesisVoice) -> String {
    if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
        switch voice.quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }
    return "Default"
}
#endif

enum KeychainStore {
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            return deleteStatus == errSecItemNotFound ? errSecSuccess : deleteStatus
        }
        let protectedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, protectedAttributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var addAttributes = query
        protectedAttributes.forEach { addAttributes[$0.key] = $0.value }
        return SecItemAdd(addAttributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

extension Gate1AppModel {
    enum PendingPlaybackAfterTerms {
        case startCurrentItem
        case resumeSession(String)
        case jumpToChapter(String, fromTimeline: Bool)
        case playSourceFromBeginning(fromTimeline: Bool)
    }

    static func availableSpeechVoiceOptions() -> [SpeechVoiceChoice] {
        #if canImport(AVFoundation)
        // `AVSpeechSynthesisVoice.speechVoices()` can crash inside the iOS
        // Simulator's AXSpeech process while XCTest is attaching. The system
        // default voice still works there, so do not cross that unstable
        // framework boundary on Simulator. Real devices retain the complete
        // installed-voice picker.
        guard supportsSpeechVoiceEnumeration else { return [] }
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name < rhs.name
                }
                return lhs.language < rhs.language
            }
            .map { voice in
                SpeechVoiceChoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: voiceQualityName(voice)
                )
            }
        #else
        return []
        #endif
    }

    func migrateTTSSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.supertonicTTSMigrationKey) else {
            synchronizeTTSModeFromSelection()
            return
        }

        // This is intentionally a one-way pre-1.0 migration. Legacy experimental
        // and system-only modes all move to the bundled default voice;
        // the prior Apple voice identifier remains available for fallback.
        ttsVoiceSelection = .james
        ttsMode = "supertonic"
        defaults.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        defaults.set(ttsMode, forKey: "ttsMode")
        defaults.set(true, forKey: Self.supertonicTTSMigrationKey)
    }

    private func synchronizeTTSModeFromSelection() {
        ttsMode = ttsVoiceSelection == .system ? "systemImmediate" : "supertonic"
    }

    func enforceTermsGateForStoredVoice() {
        let defaults = UserDefaults.standard
        hasAcceptedCurrentTerms = SpokenMarginsTerms.hasAcceptedCurrentVersion()
            && SpokenMarginsTerms.hasBundledText()
        acceptedTermsVersion = SpokenMarginsTerms.acceptedVersion()
        if hasAcceptedCurrentTerms {
            defaults.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
            return
        }
        if ttsVoiceSelection.supertonicVoice != nil {
            pendingTermsVoiceSelection = ttsVoiceSelection
            defaults.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
        } else if let rawValue = defaults.string(forKey: Self.supertonicVoicePendingTermsKey),
                  let pendingVoice = AppTTSVoiceSelection(rawValue: rawValue),
                  pendingVoice.supertonicVoice != nil {
            pendingTermsVoiceSelection = pendingVoice
        }
        guard pendingTermsVoiceSelection != nil else { return }
        ttsVoiceSelection = .system
        synchronizeTTSModeFromSelection()
        defaults.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        defaults.set(ttsMode, forKey: "ttsMode")
    }

    var termsAcceptanceDescription: String {
        if hasAcceptedCurrentTerms {
            return "Accepted version \(SpokenMarginsTerms.currentVersion)"
        }
        if let acceptedTermsVersion {
            return "Version \(acceptedTermsVersion) expired"
        }
        return "Not accepted · iOS voice only"
    }

    func acceptCurrentTermsAndEnableOnDeviceVoice() {
        guard SpokenMarginsTerms.hasBundledText() else {
            pendingTermsVoiceSelection = nil
            isTermsOfUsePresented = false
            ttsVoiceSelection = .system
            saveSpeechSettings()
            reportFailure(SpokenMarginsTermsError.bundledTermsUnavailable, context: "Terms acceptance failed")
            return
        }
        let pendingPlayback = pendingPlaybackAfterTerms
        pendingPlaybackAfterTerms = nil
        SpokenMarginsTerms.recordAcceptance()
        hasAcceptedCurrentTerms = true
        acceptedTermsVersion = SpokenMarginsTerms.currentVersion
        isTermsOfUsePresented = false
        ttsVoiceSelection = pendingTermsVoiceSelection ?? .james
        pendingTermsVoiceSelection = nil
        UserDefaults.standard.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
        saveSpeechSettings()
        if let engine {
            snapshot = (try? engine.stopPlayback()) ?? snapshot
            refreshSelectedItem()
        }
        _ = rebuildEngineForCurrentSettings()
        diagnostics["termsAcceptedVersion"] = SpokenMarginsTerms.currentVersion
        reportConfirmation("Terms accepted. \(ttsVoiceSelection.displayName) is enabled.")
        continuePlaybackAfterTerms(pendingPlayback)
    }

    func declineCurrentTerms() {
        let pendingPlayback = pendingPlaybackAfterTerms
        pendingPlaybackAfterTerms = nil
        pendingTermsVoiceSelection = nil
        UserDefaults.standard.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
        isTermsOfUsePresented = false
        ttsVoiceSelection = .system
        saveSpeechSettings()
        reportSuccess("The iOS system voice remains enabled.")
        continuePlaybackAfterTerms(pendingPlayback)
    }

    func requireTermsDecisionBeforePlayback(_ action: PendingPlaybackAfterTerms) -> Bool {
        guard !hasAcceptedCurrentTerms, pendingTermsVoiceSelection?.supertonicVoice != nil else {
            return false
        }
        pendingPlaybackAfterTerms = action
        isTermsOfUsePresented = true
        diagnostics["termsGate"] = "presented_for_first_playback"
        statusMessage = "Choose whether to enable the improved on-device voice before playback begins."
        return true
    }

    private func continuePlaybackAfterTerms(_ action: PendingPlaybackAfterTerms?) {
        guard let action else { return }
        switch action {
        case .startCurrentItem:
            start()
        case .resumeSession(let sessionId):
            guard let session = try? store?.loadSession(id: sessionId) else {
                reportFailure("The listening session could not be restored after choosing a voice.")
                return
            }
            resumeSession(session)
        case .jumpToChapter(let chapterId, let fromTimeline):
            if let chapter = selectedItem.chapters.first(where: { $0.id == chapterId }) {
                jumpToChapter(chapter, fromTimeline: fromTimeline)
            } else if let chapter = selectedItem.mediaChapters.first(where: { $0.id == chapterId }) {
                jumpToMediaChapter(chapter, fromTimeline: fromTimeline)
            } else {
                reportFailure("The selected chapter could not be restored after choosing a voice.")
            }
        case .playSourceFromBeginning(let fromTimeline):
            playSourceFromBeginning(fromTimeline: fromTimeline)
        }
    }

    var aiDataSharingConsentDescription: String {
        switch aiDataSharingConsent {
        case .unknown: return "Not decided"
        case .grantedV1: return "Allowed for live OpenAI requests"
        case .declined: return "Not allowed"
        }
    }

    var remoteProviderExperienceEnabled: Bool {
        featureFlags.remoteProviderExperienceEnabled
    }

    var localFoundationModelAvailable: Bool {
        localFoundationModelAvailability.isAvailable
    }

    var localFoundationModelAvailabilityDescription: String {
        localFoundationModelAvailability.description
    }

    var aiSummaryExperienceAvailable: Bool {
        remoteProviderExperienceEnabled || localFoundationModelAvailable
    }

    var canGenerateListeningMap: Bool {
        guard selectedItem.chapters.isEmpty,
              selectedItem.mediaChapters.isEmpty,
              selectedItem.listeningMapScenes.isEmpty else { return false }
        guard let item = try? store?.loadItem(id: activeItemId) else { return false }
        return item.media?.sourceType == .nativeMediaFile
            || item.media?.sourceType == .remoteStream
            || remoteProviderExperienceEnabled
            || item.media == nil
    }

    var listeningMapGenerationAvailabilityDescription: String {
        if !selectedItem.listeningMapScenes.isEmpty {
            return "This item has a private Listening Map with \(selectedItem.listeningMapScenes.count) scene\(selectedItem.listeningMapScenes.count == 1 ? "" : "s")."
        }
        if !selectedItem.mediaChapters.isEmpty {
            return "This podcast already includes publisher chapters. A generated Listening Map is unnecessary."
        }
        if !selectedItem.chapters.isEmpty {
            return "This item already has a Listening Map."
        }
        guard let item = try? store?.loadItem(id: activeItemId) else {
            return "Listening Map generation is unavailable."
        }
        if item.media != nil {
            return "Prepare a private episode fingerprint map. Supported iOS 26 devices also generate on-device scene summaries."
        }
        return "Listening Map generation is unavailable."
    }

    static func storedMediaSkipSeconds(forKey key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return supportedMediaSkipSeconds.contains(value) ? value : 15
    }

    static func storedRenderedSpeechCacheLimitMB() -> Int {
        let value = UserDefaults.standard.integer(forKey: "renderedSpeechCacheLimitMB")
        return supportedRenderedSpeechCacheLimitsMB.contains(value) ? value : 256
    }

    func grantAIDataSharingConsent() {
        aiDataSharingConsent = .grantedV1
        UserDefaults.standard.set(aiDataSharingConsent.rawValue, forKey: "aiDataSharingConsent")
        isAIDataSharingConsentPresented = false
        diagnostics["aiDataSharingConsent"] = aiDataSharingConsent.rawValue

        let pendingJob = pendingProviderJobForConsent
        pendingProviderJobForConsent = nil
        let shouldGenerateMap = pendingMapGenerationAfterConsent
        pendingMapGenerationAfterConsent = false
        if shouldGenerateMap {
            generateListeningMap()
        }
        if let pendingJob {
            submitProviderJobIfNeeded(
                kind: pendingJob.kind,
                turnId: pendingJob.turnId,
                messages: pendingJob.messages,
                force: pendingJob.force
            )
        }
    }

    func declineAIDataSharingConsent() {
        aiDataSharingConsent = .declined
        UserDefaults.standard.set(aiDataSharingConsent.rawValue, forKey: "aiDataSharingConsent")
        isAIDataSharingConsentPresented = false
        pendingMapGenerationAfterConsent = false
        if pendingProviderJobForConsent != nil {
            markProviderFailure("ai_data_sharing_not_allowed", userMessage: "Live AI request cancelled. No content was sent.")
        } else {
            reportConfirmation("Live AI request cancelled. No content was sent.")
        }
        pendingProviderJobForConsent = nil
    }

    func revokeAIDataSharingConsent() {
        aiDataSharingConsent = .unknown
        UserDefaults.standard.removeObject(forKey: "aiDataSharingConsent")
        pendingProviderJobForConsent = nil
        pendingMapGenerationAfterConsent = false
        diagnostics["aiDataSharingConsent"] = aiDataSharingConsent.rawValue
        reportConfirmation("OpenAI data-sharing permission revoked.")
    }

    func deleteProviderAPIKey() {
        let existingKey = providerAPIKey
        providerAPIKey = ""
        let status = KeychainStore.save("", service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        guard status == errSecSuccess else {
            providerAPIKey = existingKey
            diagnostics["keychainStatus"] = "delete_failed:\(status)"
            reportFailure("The OpenAI API key could not be deleted from Keychain (\(status)).")
            return
        }
        diagnostics["apiKeyConfigured"] = "false"
        diagnostics["keychainStatus"] = "deleted"
        _ = rebuildEngineForCurrentSettings()
        reportConfirmation("OpenAI API key deleted from Keychain.")
    }

    func importPiperVoiceAssets(urls: [URL]) {
        guard !urls.isEmpty else {
            reportFailure("No Piper voice files were selected.")
            return
        }

        do {
            let assetsDirectory = try piperAssetsDirectory()
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

            var copied: [String] = []
            var ignored: [String] = []

            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard isSupportedPiperVoiceAsset(url) else {
                    ignored.append(url.lastPathComponent)
                    continue
                }

                let destinationURL = assetsDirectory.appending(path: url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                copied.append(url.lastPathComponent)
            }

            refreshPiperVoiceStatus()
            let ignoredSuffix = ignored.isEmpty ? "" : " Ignored: \(ignored.joined(separator: ", "))."
            if copied.isEmpty {
                reportFailure("No Piper assets were imported. Select a .onnx voice model and its .onnx.json config.\(ignoredSuffix)")
            } else {
                reportConfirmation("Imported Piper asset\(copied.count == 1 ? "" : "s").\(ignoredSuffix)")
            }
        } catch {
            reportFailure(error, context: "Piper voice import failed")
        }
    }

    func openSettings() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_settings") else { return }
        screen = .settings
    }

    func openHelp() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_help") else { return }
        isHelpPresented = true
    }

    func openAISettingsFromSummaryPrompt() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings") else { return }
        isAISetupNeededPresented = false
        screen = .settings
    }

    func mediaSkipSettingsChanged() {
        mediaSkipBackSeconds = Self.validatedMediaSkipSeconds(mediaSkipBackSeconds)
        mediaSkipForwardSeconds = Self.validatedMediaSkipSeconds(mediaSkipForwardSeconds)
        UserDefaults.standard.set(mediaSkipBackSeconds, forKey: "mediaSkipBackSeconds")
        UserDefaults.standard.set(mediaSkipForwardSeconds, forKey: "mediaSkipForwardSeconds")
        mediaPlaybackClient?.setPreferredSkipIntervals(
            backSeconds: mediaSkipBackSeconds,
            forwardSeconds: mediaSkipForwardSeconds
        )
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
    }

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

    func podcastCacheLimitChanged() {
        guard let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) else {
            podcastCacheLimitGB = PodcastCacheLimitGB.defaultValue.rawValue
            return
        }
        UserDefaults.standard.set(limit.rawValue, forKey: "podcastCacheLimitGB")
        podcastDownloadCoordinator?.setCacheLimit(limit)
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
        reportSuccess("Podcast cache limit set to \(limit.rawValue) GB.")
    }

    func renderedSpeechCacheLimitChanged() {
        guard Self.supportedRenderedSpeechCacheLimitsMB.contains(renderedSpeechCacheLimitMB) else {
            renderedSpeechCacheLimitMB = 256
            return
        }
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        renderedSpeechDiskCache?.setLimitBytes(renderedSpeechCacheLimitMB * 1024 * 1024)
        diagnostics["renderedSpeechCacheLimitMB"] = "\(renderedSpeechCacheLimitMB)"
        reportSuccess("Rendered speech cache limit set to \(renderedSpeechCacheLimitMB) MB.")
    }

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
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
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
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        cancelTextAudioPrewarmTasks()
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
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
        } else if ttsVoiceSelection.supertonicVoice != nil, audioPlaybackClientOverride == nil {
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
        if ttsVoiceSelection.supertonicVoice != nil, !hasAcceptedCurrentTerms {
            pendingTermsVoiceSelection = ttsVoiceSelection
            UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            diagnostics["termsGate"] = "presented_for_on_device_voice"
            statusMessage = "Review the Terms of Use to enable an on-device voice."
            return
        }
        sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        if let engine {
            snapshot = (try? engine.stopPlayback()) ?? snapshot
            refreshSelectedItem()
        }
        _ = rebuildEngineForCurrentSettings()
        if ttsVoiceSelection == .system, let renderer = supertonicRenderer {
            supertonicRenderer = nil
            Task { await renderer.unload() }
        }
        reportSuccess("Voice changed to \(ttsVoiceSelection.displayName). Press play when you are ready.")
    }

    func previewSpokenContentVoice() {
        previewSpeech(label: "Spoken Content settings", mode: .spokenContent)
    }

    func previewAppVoice() {
        saveSpeechSettings()
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let renderer = try self.makeSupertonicRenderer()
                let result = try await renderer.render(
                    text: "Spoken Margins is ready to read with your selected on-device voice.",
                    voice: voice,
                    speed: speed,
                    synthesisSteps: 8
                )
                try Task.checkCancellation()
                try self.playSupertonicPreview(url: result.audioURL)
                self.diagnostics["supertonicPreviewRenderSeconds"] = String(format: "%.3f", result.renderDuration)
                self.diagnostics["supertonicPreviewDurationSeconds"] = String(format: "%.3f", result.duration)
                self.diagnostics["supertonicSessionLoadCount"] = "\(result.sessionLoadCount)"
                self.reportSuccess("Playing \(self.ttsVoiceSelection.displayName).")
            } catch {
                self.reportFailure(error, context: "On-device voice preview failed")
            }
            self.isRenderingSupertonicPreview = false
        }
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

    func refreshPiperVoiceStatus() {
        do {
            piperVoiceOptions = try discoverPiperVoiceOptions()
            if piperVoiceId.isEmpty, let first = piperVoiceOptions.first {
                piperVoiceId = first.id
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            } else if !piperVoiceId.isEmpty, !piperVoiceOptions.contains(where: { $0.id == piperVoiceId }) {
                piperVoiceId = piperVoiceOptions.first?.id ?? ""
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            }
            if piperVoiceOptions.isEmpty {
                piperStatus = "No Piper voices installed. Import a .onnx model and .onnx.json config."
            } else if let selected = piperVoiceOptions.first(where: { $0.id == piperVoiceId }) {
                piperStatus = "Selected \(selected.displayName). Piper renderer not linked in this build; playback will fail instead of falling back to system speech."
            } else {
                piperStatus = "\(piperVoiceOptions.count) Piper voice\(piperVoiceOptions.count == 1 ? "" : "s") installed."
            }
            diagnostics["piperVoices"] = "\(piperVoiceOptions.count)"
            diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
            diagnostics["piperStatus"] = piperStatus
        } catch {
            piperVoiceOptions = []
            piperStatus = "Piper voice check failed: \(error.localizedDescription)"
            diagnostics["piperStatus"] = piperStatus
        }
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
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
            return "\(ttsVoiceSelection.displayName) (Supertonic \(ttsVoiceSelection.supertonicVoice?.rawValue ?? ""))"
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
        return String(format: "System %.2fx", speechPlaybackRateMultiplier)
    }

    var speechPlaybackRateMultiplier: Double {
        max(0.5, min(2.0, ((speechRate / 0.5) * 4).rounded() / 4))
    }

    var hasConfiguredProviderAPIKey: Bool {
        !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func previewSpeech(label: String, mode: AppSpeechPreviewMode) {
        #if canImport(AVFoundation)
        do {
            if speechPreviewSynthesizer.isSpeaking {
                speechPreviewSynthesizer.stopSpeaking(at: .immediate)
            }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let utterance = AVSpeechUtterance(string: "Spoken Margins preview. This is the \(label) path.")
            switch mode {
            case .spokenContent:
                utterance.rate = SpeechRateRule.systemSpeechRate(forMultiplier: speechPlaybackRateMultiplier)
            case .appVoice(let voiceIdentifier, let rate):
                utterance.rate = SpeechRateRule.systemSpeechRate(
                    forMultiplier: SpeechRateRule.multiplier(forStoredRate: rate)
                )
                if let voiceIdentifier,
                   let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                    utterance.voice = configuredVoice
                }
            case .assistiveTechnology:
                utterance.rate = Float(speechRate)
                utterance.prefersAssistiveTechnologySettings = true
            }
            speechPreviewSynthesizer.speak(utterance)
            diagnostics["lastSpeechPreview"] = label
            reportSuccess("Previewing \(label).")
        } catch {
            reportFailure(error, context: "Speech preview failed")
        }
        #else
        reportFailure("Speech preview unavailable on this platform.")
        #endif
    }

    #if canImport(AVFoundation)
    func stopSpeechPreviews() {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        supertonicPreviewPlayer?.stop()
    }

    private func playSupertonicPreview(url: URL) throws {
        stopSpeechPreviews()
        if let priorURL = supertonicPreviewURL, let renderer = supertonicRenderer {
            Task { await renderer.discardGeneratedAudio(at: priorURL) }
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
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
    func stopSpeechPreviews() {}
    #endif

    private func piperAssetsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(path: "Piper", directoryHint: .isDirectory)
    }

    private func isSupportedPiperVoiceAsset(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".onnx") || lowercasedName.hasSuffix(".onnx.json")
    }

    private func discoverPiperVoiceOptions() throws -> [PiperVoiceOption] {
        let directory = try piperAssetsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".onnx") }
            .compactMap { modelURL -> PiperVoiceOption? in
                let voiceId = piperVoiceId(forModelURL: modelURL)
                guard !voiceId.isEmpty else { return nil }
                let configURL = piperConfigURL(forVoiceId: voiceId, in: directory)
                let metadata = piperVoiceMetadata(configURL: configURL)
                return PiperVoiceOption(
                    id: voiceId,
                    name: metadata.name ?? piperDisplayName(for: voiceId),
                    language: metadata.language ?? "",
                    modelURL: modelURL,
                    configURL: configURL
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func piperVoiceId(forModelURL url: URL) -> String {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".onnx") else { return "" }
        return String(name.dropLast(5))
    }

    private func piperConfigURL(forVoiceId voiceId: String, in directory: URL) -> URL? {
        let candidates = [
            directory.appending(path: "\(voiceId).onnx.json"),
            directory.appending(path: "\(voiceId).json")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func piperDisplayName(for voiceId: String) -> String {
        voiceId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private func piperVoiceMetadata(configURL: URL?) -> (name: String?, language: String?) {
        guard let configURL,
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let dataset = object["dataset"] as? String
        let language = object["language"] as? [String: Any]
        let languageCode = language?["code"] as? String
        let languageName = language?["name"] as? String
        return (
            dataset?.isEmpty == false ? dataset : nil,
            languageName ?? languageCode
        )
    }

    func rebuildEngineForCurrentSettings() -> Bool {
        guard let store else { return true }
        do {
            foregroundAudioPreparationTask?.cancel()
            foregroundAudioPreparationGeneration += 1
            foregroundAudioPreparationTask = nil
            pendingStartupAudioPreparationItemIds.removeAll()
            let replacement = try makeEngine(store: store)
            let sessionId = engine?.currentSession?.id ?? snapshot.sessionId
            if engine?.currentSession != nil {
                snapshot = try engine?.stopPlayback() ?? snapshot
            }
            let restoredSnapshot = try sessionId.map { try replacement.inspectSession(sessionId: $0) }
            installEngine(replacement)
            try refreshLibraryRows(store: store)
            if let restoredSnapshot {
                snapshot = restoredSnapshot
                activeItemId = restoredSnapshot.itemId ?? activeItemId
                try prepareSourceMediaPlayback(itemId: activeItemId)
                refreshSelectedItem()
                diagnostics["sessionRestoredAfterRuntimeRebuild"] = sessionId
            }
            return true
        } catch {
            reportFailure(error, context: "Runtime profile update failed")
            return false
        }
    }

    func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
        let loadedProfile = try loadProfile(id: selectedProfileId)
        let profile = runtimeProfileForFeatureFlags(loadedProfile)
        let provider: AIProviderClient
        if !remoteProviderExperienceEnabled {
            provider = AppleFoundationAIProvider()
        } else if let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            provider = OpenAICompatibleProvider(baseURL: url, model: fallbackProviderModel(), apiKeyReference: providerAPIKey.isEmpty ? nil : "keychain:SpokenMargins/OpenAICompatibleAPIKey")
        } else {
            provider = FixtureAIProvider()
        }
        return SessionEngine(
            profile: profile,
            repository: store,
            audio: try makeAudioPlaybackClient(),
            recorder: recordingClientOverride ?? SystemRecordingClient(),
            aiProvider: provider,
            linkResolver: sourceLinkResolver ?? PublicPodcastLinkResolver(),
            textAudio: try makeTextAudioPreparationClient()
        )
    }

    private func runtimeProfileForFeatureFlags(_ profile: RuntimeCapabilityProfile) -> RuntimeCapabilityProfile {
        guard !remoteProviderExperienceEnabled else { return profile }
        var capabilities = profile.capabilities
        let allowedLocalAI = localFoundationModelAvailable
            ? Set(["generate_listening_map", "summarize_interjections", "cleanup_transcript", "defer_ai_jobs"])
            : Set(["cleanup_transcript", "defer_ai_jobs"])
        capabilities["ai"] = capabilities["ai", default: []].filter(allowedLocalAI.contains)
        return RuntimeCapabilityProfile(
            id: "\(profile.id)-local-foundation",
            displayName: "\(profile.displayName) · On-device AI",
            capabilities: capabilities,
            forbiddenCapabilities: Array(Set(profile.forbiddenCapabilities).union([
                "provider_diagnostics",
                "continue_discussion"
            ])).sorted()
        )
    }

    @discardableResult
    func sanitizeTTSMode() -> Bool {
        let priorMode = ttsMode
        if ttsVoiceSelection.supertonicVoice != nil, !hasAcceptedCurrentTerms {
            ttsVoiceSelection = .system
        }
        synchronizeTTSModeFromSelection()
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        return priorMode != ttsMode
    }

    func loadProfile(id: String) throws -> RuntimeCapabilityProfile {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "fixtures/capabilities") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.profile(at: url)
    }
}
