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

/// Skim forward and back, and the summary bridge audio that plays between (#1016), moved unchanged out of the central model.
extension Gate1AppModel {
    var skimForwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimForwardDestinationMs, backward: false) }

    var skimBackwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimBackwardDestinationMs, backward: true) }

    #if DEBUG
    var skimAudioTransportRate: Float? { skimBridgePlayer?.rate }

    func refreshSkimAvailabilityForTesting() { updateSkimAvailability() }
    #endif

    func updateSkimAvailability(refreshResources: Bool = true) {
        if refreshResources { skimResourceContext = nil }
        guard !isUpdatingSkimAvailability else { return }
        let effectiveTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? snapshot.currentMediaTimeMs
        let forward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) }
        let backward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .backward, at: $0) }
        let forwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        let destinationsChanged = skimForwardDestinationMs != forwardTime || skimBackwardDestinationMs != backwardTime
        if destinationsChanged { (skimForwardDestinationMs, skimBackwardDestinationMs) = (forwardTime, backwardTime) }
        let canForward = forwardTime != nil, canBackward = backwardTime != nil
        // A map can move where Skim lands with no availability flip (paused, say); the Lock Screen still needs it (#115).
        guard snapshot.canSkimForward != canForward || snapshot.canSkimBackward != canBackward else { if destinationsChanged { updateGate2CompactState() }; return }
        isUpdatingSkimAvailability = true
        snapshot.canSkimForward = canForward
        snapshot.canSkimBackward = canBackward
        isUpdatingSkimAvailability = false
    }

    func resolvedSkimPlaybackPlan(
        direction: SkimDirection,
        at recipientMediaTimeMs: Int
    ) -> ResolvedSkimPlaybackPlan? {
        guard isMediaPlaybackSnapshot, !snapshot.isRecording, let store else { return nil }
        if skimResourceContext?.itemId != activeItemId {
            #if DEBUG
            skimResourceLoadCount += 1
            #endif
            let projection = try? store.loadResolvedListeningMapProjection(itemId: activeItemId)
            skimResourceContext = SkimResourceContext(
                itemId: activeItemId,
                projection: projection,
                proposal: SharedListeningMapPlacement.proposal(
                    for: projection, committed: (try? store.loadPortableListeningMapProposals(itemId: activeItemId)) ?? [],
                    layers: (try? store.loadImportedCommentaryLayers(itemId: activeItemId)) ?? []),
                assets: (try? store.loadOwnedOfflineAssets()) ?? []
            )
        }
        guard let resources = skimResourceContext, let projection = resources.projection else { return nil }
        guard let proposal = resources.proposal else { return nil }
        guard let plan = SceneStarts(scenes: proposal.scenes, projection: projection).skimPlan(
            direction: direction, at: recipientMediaTimeMs,
            durationMs: snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs
        ) else { return nil }
        let summaryScene = plan.summaryScene
        let assetID = summaryBridgeAssetID(
            itemId: activeItemId,
            proposalId: SharedListeningMapPlacement.isSharedProjection(id: projection.id) ? projection.id : proposal.id,
            sceneId: summaryScene.id,
            suppliedAssetId: summaryScene.summaryAssetId
        )
        guard let asset = resources.assets.first(where: {
            $0.id == assetID && $0.category == .summaryBridge && $0.integrity == .valid
        }), let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) else {
            return nil
        }
        return ResolvedSkimPlaybackPlan(
            direction: direction,
            itemId: activeItemId,
            originMediaTimeMs: recipientMediaTimeMs,
            summarySceneId: summaryScene.id,
            destinationSceneId: plan.destinationSceneId,
            destinationMediaTimeMs: plan.destinationMediaTimeMs,
            summaryAssetId: assetID,
            summaryAudioURL: url
        )
    }

    func skimForward() {
        performSkim(direction: .forward)
    }

    func skimBackward() {
        performSkim(direction: .backward)
    }

    private func performSkim(direction: SkimDirection) {
        if snapshot.skimBridgeState != nil {
            // A second tap exits the current bridge at its destination. Do not
            // resolve another summary against the asynchronous source seek.
            completeSkimBridge()
            return
        }
        let effectiveTime = snapshot.currentMediaTimeMs ?? 0
        guard let plan = resolvedSkimPlaybackPlan(direction: direction, at: effectiveTime) else {
            reportWarning("Skim is unavailable until a verified scene summary is ready.")
            return
        }
        startSkimBridge(plan)
    }

    func startSkimBridge(_ plan: ResolvedSkimPlaybackPlan, continueAfterSummary: Bool = false) {
        #if canImport(AVFoundation)
        guard let engine else { return }
        let wasPlaying = snapshot.status.isPlaybackActive || continueAfterSummary
        do {
            snapshot = try engine.pause()
            var state = SkimBridgeState(
                direction: plan.direction,
                itemId: plan.itemId,
                originMediaTimeMs: plan.originMediaTimeMs,
                summarySceneId: plan.summarySceneId,
                destinationSceneId: plan.destinationSceneId,
                destinationMediaTimeMs: plan.destinationMediaTimeMs,
                summaryAssetId: plan.summaryAssetId,
                wasSourcePlaying: wasPlaying,
                status: .preparing
            )
            snapshot.skimBridgeState = state
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: true)
            let player = AVPlayer(url: plan.summaryAudioURL)
            skimBridgePlayer = player
            state.status = .playing
            snapshot.skimBridgeState = state
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            skimBridgeTask?.cancel()
            skimBridgeTask = Task { @MainActor [weak self, weak player] in
                while !Task.isCancelled {
                    guard let self, let player, let item = player.currentItem else { return }
                    if item.status == .failed {
                        self.cancelSkimBridge(restoringOrigin: true, resumeSource: false)
                        self.reportWarning("The scene summary could not be played. Your original position was restored.")
                        return
                    }
                    let duration = CMTimeGetSeconds(item.duration)
                    let current = CMTimeGetSeconds(player.currentTime())
                    if duration.isFinite, duration > 0, current >= duration - 0.08 {
                        self.completeSkimBridge()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            reportSuccess(plan.direction == .forward ? "Skimming forward." : "Skimming backward.")
        } catch {
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: false)
            reportFailure(error, context: "Skim failed")
        }
        #else
        reportWarning("Skim audio is unavailable on this device.")
        #endif
    }

    func completeSkimBridge() {
        guard var bridge = snapshot.skimBridgeState, let engine else { return }
        bridge.status = .completing
        snapshot.skimBridgeState = bridge
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        do {
            snapshot.skimBridgeState = nil
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: bridge.destinationMediaTimeMs)
            if bridge.destinationSceneId == nil {
                snapshot = try engine.pause()
                reportConfirmation("Finished the final scene summary.")
            } else if bridge.wasSourcePlaying {
                snapshot = try engine.resumePlayback()
            } else {
                snapshot = try engine.pause()
            }
            refreshSelectedItem()
        } catch {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
            reportFailure(error, context: "Completing Skim failed")
        }
    }

    func setSkimBridgePaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard var bridge = snapshot.skimBridgeState, let player = skimBridgePlayer else { return }
        if paused {
            player.pause()
            bridge.status = .paused
        } else {
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            bridge.status = .playing
        }
        snapshot.skimBridgeState = bridge
        #endif
    }

    func returnFromSkim() {
        cancelSkimBridge(restoringOrigin: true, resumeSource: true)
    }

    func cancelSkimBridge(restoringOrigin: Bool, resumeSource: Bool) {
        guard var bridge = snapshot.skimBridgeState else { return }
        bridge.status = .cancelled
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        snapshot.skimBridgeState = nil
        guard restoringOrigin, let engine else { return }
        snapshot = (try? seekOrStageMedia(engine, toMediaTimeMs: bridge.originMediaTimeMs)) ?? snapshot
        if resumeSource && bridge.wasSourcePlaying {
            snapshot = (try? engine.resumePlayback()) ?? snapshot
        } else {
            snapshot = (try? engine.pause()) ?? snapshot
        }
    }

    func restoreSkimOriginBeforeCanonicalTransport() {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        guard let bridge = snapshot.skimBridgeState else { return }
        cancelSkimBridge(restoringOrigin: true, resumeSource: bridge.wasSourcePlaying)
    }

    private func protectSummaryBridgeAsset(_ assetID: String, protected: Bool) {
        _ = try? store?.updateOwnedOfflineAsset(id: assetID) { asset in
            if protected {
                asset.protections.insert(.activeSummaryBridge)
            } else {
                asset.protections.remove(.activeSummaryBridge)
            }
        }
    }
}
