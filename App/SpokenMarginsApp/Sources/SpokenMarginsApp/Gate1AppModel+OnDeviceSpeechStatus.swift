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

/// On-device speech generation status and retry (#961), moved unchanged out of the central model.
extension Gate1AppModel {
    var preparedTextAudioStatusDescription: String {
        PlaybackStatusWording.humanReadableStatus(preparedTextAudioStatus)
    }

    var shouldShowOnDeviceSpeechGenerationStatus: Bool {
        Self.supportsOnDeviceSpeechGenerationStatus(targetType: snapshot.targetType)
            && ttsVoiceSelection.isOnDeviceVoice
            && onDeviceSpeechGenerationStatus != RenderedSpeechGenerationState.inactive.rawValue
    }

    var canStopOnDeviceSpeechGeneration: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var isOnDeviceSpeechGenerating: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var canRetryOnDeviceSpeechGeneration: Bool {
        guard speechPlaybackClient is SupertonicSpeechPlaybackClient, snapshot.targetId != nil, snapshot.sessionId != nil else { return false }
        return onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.stopped.rawValue
            || preparedTextAudioStatus == "failed"
    }

    func retryOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
              let targetId = snapshot.targetId,
              let sessionId = snapshot.sessionId else {
            reportFailure("There is no current Supertonic response to retry.")
            return
        }
        let itemId = snapshot.itemId
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let coordinator = self.preparedAudioCoordinator,
                   let signature = self.currentSupertonicRenderSignature {
                    try await coordinator.retry(itemId: targetId, signature: signature)
                }
                guard self.snapshot.sessionId == sessionId, self.snapshot.targetId == targetId else { return }
                if let itemId { self.allowAudioPreparation(itemId: itemId) }
                guard try client.retryOnDeviceRendering() else { return }
                self.speechFallbackReason = nil
                self.preparedTextAudioStatus = "preparing"
                self.diagnostics["onDeviceSpeechGeneration"] = "retry_current_target"
                self.reportConfirmation("Retrying Supertonic at the current position.")
            } catch {
                self.reportFailure(error, context: "Prepared audio retry failed", itemId: itemId)
            }
        }
    }

    var onDeviceSpeechGenerationStatusDescription: String {
        (RenderedSpeechGenerationState(rawValue: onDeviceSpeechGenerationStatus) ?? .inactive).listenerDescription(
            progress: onDeviceSpeechGenerationProgress, isDelayed: isOnDeviceSpeechGenerationDelayed,
            stopReason: onDeviceSpeechGenerationStopReason, fallbackReason: speechFallbackReason
        )
    }

    func updateOnDeviceSpeechGenerationState(_ state: RenderedSpeechGenerationState, stopReason: String?) {
        if onDeviceSpeechGenerationStatus != state.rawValue { onDeviceSpeechGenerationStatus = state.rawValue }
        if onDeviceSpeechGenerationStopReason != stopReason { onDeviceSpeechGenerationStopReason = stopReason }
        // Rendering, ready or idle: the iOS voice isn't standing in, so an old reason is stale (#314).
        if state != .stopped, speechFallbackReason != nil { speechFallbackReason = nil }
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        diagnostics["onDeviceSpeechGeneration"] = state.rawValue
        diagnostics["onDeviceSpeechGenerationStopReason"] = stopReason
        guard state != .rendering else { return }
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        isOnDeviceSpeechGenerationDelayed = false
        if state == .inactive {
            onDeviceSpeechGenerationProgress = RenderedSpeechGenerationProgress(
                completedChunks: 0,
                totalChunks: 0
            )
        }
    }

    func updateOnDeviceSpeechGenerationProgress(_ progress: RenderedSpeechGenerationProgress) {
        guard onDeviceSpeechGenerationProgress != progress else { return }
        onDeviceSpeechGenerationProgress = progress
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        isOnDeviceSpeechGenerationDelayed = false
        diagnostics["onDeviceSpeechGenerationProgress"] = "\(progress.completedChunks)/\(progress.totalChunks)"
            + (progress.isRestingAhead ? " resting" : "")
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        guard progress.watchesForDelay else { return }
        onDeviceSpeechGenerationDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self,
                  self.onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue,
                  self.onDeviceSpeechGenerationProgress == progress else { return }
            self.isOnDeviceSpeechGenerationDelayed = true
            self.diagnostics["onDeviceSpeechGenerationDelay"] = "chunk_\(progress.completedChunks + 1)_over_45s"
        }
    }

    var sourceTranscriptStatusDescription: String {
        PlaybackStatusWording.humanReadableStatus(sourceTranscriptStatus)
    }
}
