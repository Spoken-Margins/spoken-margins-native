import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
#if canImport(AVFoundation)
import AVFoundation
#endif

/// What the Skim bridge reads of the item that is playing; nil when Skim has nothing to resolve against
/// (not a media item, a recording in progress, no store).
struct SkimSource {
    let itemId: String
    /// The playing duration, or the item's own when the snapshot has none yet.
    let durationMs: Int?
}

/// What the Skim bridge asks of the model that owns it (#954). The controller holds its host weakly and never
/// writes the snapshot except through `skimBridgeState` and `skimAvailability`, so the model's snapshot observer
/// still sees every change, as it did when the model itself wrote them.
@MainActor
protocol SkimBridgeHost: AnyObject {
    /// `snapshot.skimBridgeState`: the one record of a bridge in flight. The engine replaces the snapshot on every call,
    /// so the controller sets and clears this only between engine calls, never across one.
    var skimBridgeState: SkimBridgeState? { get set }
    /// `snapshot.canSkimForward` and `canSkimBackward`. Setting them re-enters the model's snapshot observer, which asks
    /// the controller for `updateAvailability(refreshResources: false)` again; the controller's guard closes that loop.
    var skimAvailability: (forward: Bool, backward: Bool) { get set }
    var skimSourceIsPlaying: Bool { get }
    var skimCurrentMediaTimeMs: Int? { get }
    var skimSource: SkimSource? { get }
    var skimStore: SQLiteSessionStore? { get }
    var skimHasEngine: Bool { get }
    var skimMediaPlaybackRate: Double { get }

    func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String?) -> String
    func resolvedApplicationSupportAssetURL(for path: String) -> URL?

    /// Each engine call replaces the model's snapshot with the engine's result.
    func skimPauseEngine() throws
    func skimResumeEngine() throws
    func skimSeekOrStage(toMediaTimeMs mediaTimeMs: Int) throws
    /// A bridge ended at its destination: refresh what the selected item shows.
    func skimBridgeDidFinish()
    /// Cancelling asks the engine to seek and then settle, and keeps going when it refuses. The model reassigns its
    /// unchanged snapshot, so the snapshot observer runs once more, as it did when the model made those calls itself.
    func skimEngineCallFailedWhileCancelling()

    /// The destinations are about to change. The model publishes them to its observers, as its `@Published` copies did.
    func skimDestinationsWillChange()
    /// The destinations changed but the availability booleans did not, so the snapshot observer did not run; the Lock Screen still needs the new times (#115).
    func skimDestinationsChangedWithoutAvailabilityChange()

    func skimWarn(_ message: String)
    func skimSucceeded(_ message: String)
    func skimConfirmed(_ message: String)
    func skimFailed(_ error: Error, context: String)
}

/// Skim forward and back, and the summary bridge audio that plays between: its player, its poll task,
/// the resources it resolves against and the two destinations the controls show (#954).
///
/// Order of every audio change, kept from the model it came out of:
/// - start: capture the intent, pause the engine, record `preparing`, protect the asset, create the player,
///   record `playing`, set pitch and rate, start the poll.
/// - complete (natural end or a second tap): record `completing`, stop the player and poll, unprotect, clear the
///   record, seek the source to the destination, then pause or resume it (a final scene always pauses), refresh the item.
/// - cancel: stop the player and poll, unprotect, clear the record, then (optionally) seek back to the origin and pause or resume.
///
/// The poll task is not cancelled when the model goes away: it promotes the model for each 100 ms turn and ends
/// when the model is gone, as it did before the move. Destruction never seeks or resumes.
@MainActor
final class SkimBridgeController {
    private(set) var forwardDestinationMs: Int?
    private(set) var backwardDestinationMs: Int?
    #if DEBUG
    private(set) var resourceLoadCount = 0
    #endif

    private weak var host: (any SkimBridgeHost)?
    private var resourceContext: SkimResourceContext?
    private var isUpdatingAvailability = false
    #if canImport(AVFoundation)
    private var player: AVPlayer?
    private var pollTask: Task<Void, Never>?
    #endif

    init(host: any SkimBridgeHost) {
        self.host = host
    }

    #if DEBUG
    var audioTransportRate: Float? { player?.rate }
    #endif

    /// The selected item was reassigned. Only a change to what Skim resolves against, on the item it loaded for, drops
    /// the loaded map and asset metadata (#2184): every reload used to, so each tap re-read them on the main thread.
    /// Arriving at the loaded item counts as a change, so opening it reads them once. Explicit refreshes still drop them (#954).
    func itemDetailChanged(from old: SkimResourceKey, to new: SkimResourceKey) {
        guard old != new, resourceContext?.itemId == new.itemId else { return }
        resourceContext = nil
    }

    func updateAvailability(refreshResources: Bool = true) {
        if refreshResources { resourceContext = nil }
        guard !isUpdatingAvailability, let host else { return }
        let bridge = host.skimBridgeState
        let effectiveTime = bridge?.destinationMediaTimeMs ?? host.skimCurrentMediaTimeMs
        let forward = effectiveTime.flatMap { resolvedPlan(direction: .forward, at: $0) }
        let backward = effectiveTime.flatMap { resolvedPlan(direction: .backward, at: $0) }
        let forwardTime = bridge?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = bridge?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        let destinationsChanged = forwardDestinationMs != forwardTime || backwardDestinationMs != backwardTime
        if destinationsChanged {
            host.skimDestinationsWillChange()
            (forwardDestinationMs, backwardDestinationMs) = (forwardTime, backwardTime)
        }
        let canForward = forwardTime != nil, canBackward = backwardTime != nil
        let available = host.skimAvailability
        // A map can move where Skim lands with no availability flip (paused, say); the Lock Screen still needs it (#115).
        guard available.forward != canForward || available.backward != canBackward else {
            if destinationsChanged { host.skimDestinationsChangedWithoutAvailabilityChange() }
            return
        }
        isUpdatingAvailability = true
        host.skimAvailability = (canForward, canBackward)
        isUpdatingAvailability = false
    }

    func resolvedPlan(direction: SkimDirection, at recipientMediaTimeMs: Int) -> ResolvedSkimPlaybackPlan? {
        guard let host, let source = host.skimSource, let store = host.skimStore else { return nil }
        if resourceContext?.itemId != source.itemId {
            #if DEBUG
            resourceLoadCount += 1
            #endif
            let projection = try? store.loadResolvedListeningMapProjection(itemId: source.itemId)
            resourceContext = SkimResourceContext(
                itemId: source.itemId,
                projection: projection,
                proposal: SharedListeningMapPlacement.proposal(
                    for: projection, committed: (try? store.loadPortableListeningMapProposals(itemId: source.itemId)) ?? [],
                    layers: (try? store.loadImportedCommentaryLayers(itemId: source.itemId)) ?? []),
                assets: (try? store.loadOwnedOfflineAssets()) ?? []
            )
        }
        guard let resources = resourceContext, let projection = resources.projection else { return nil }
        guard let proposal = resources.proposal else { return nil }
        guard let plan = SceneStarts(scenes: proposal.scenes, projection: projection).skimPlan(
            direction: direction, at: recipientMediaTimeMs,
            durationMs: source.durationMs
        ) else { return nil }
        let summaryScene = plan.summaryScene
        let proposalId = SharedListeningMapPlacement.isSharedProjection(id: projection.id) ? projection.id : proposal.id
        let assetID = host.summaryBridgeAssetID(
            itemId: source.itemId,
            proposalId: proposalId,
            sceneId: summaryScene.id,
            suppliedAssetId: summaryScene.summaryAssetId
        )
        // A supplied voice imported before #1120 sits under the old cut name, so that name is tried after the new one.
        let legacyID = summaryScene.summaryAssetId.flatMap {
            SummaryBridgeAssetNaming.legacyAssetID(itemId: source.itemId, proposalId: proposalId, sceneId: summaryScene.id, suppliedAssetId: $0)
        }
        guard let asset = ([assetID] + (legacyID.map { [$0] } ?? [])).lazy.compactMap({ id in
            resources.assets.first(where: { $0.id == id && $0.category == .summaryBridge && $0.integrity == .valid })
        }).first, let url = host.resolvedApplicationSupportAssetURL(for: asset.relativePath) else {
            return nil
        }
        return ResolvedSkimPlaybackPlan(
            direction: direction,
            itemId: source.itemId,
            originMediaTimeMs: recipientMediaTimeMs,
            summarySceneId: summaryScene.id,
            destinationSceneId: plan.destinationSceneId,
            destinationMediaTimeMs: plan.destinationMediaTimeMs,
            summaryAssetId: asset.id,
            summaryAudioURL: url
        )
    }

    func perform(direction: SkimDirection) {
        guard let host else { return }
        if host.skimBridgeState != nil {
            // A second tap exits the current bridge at its destination. Do not
            // resolve another summary against the asynchronous source seek.
            complete()
            return
        }
        let effectiveTime = host.skimCurrentMediaTimeMs ?? 0
        guard let plan = resolvedPlan(direction: direction, at: effectiveTime) else {
            host.skimWarn("Skim is unavailable until a verified scene summary is ready.")
            return
        }
        start(plan)
    }

    func start(_ plan: ResolvedSkimPlaybackPlan, continueAfterSummary: Bool = false) {
        guard let host else { return }
        #if canImport(AVFoundation)
        guard host.skimHasEngine else { return }
        let wasPlaying = host.skimSourceIsPlaying || continueAfterSummary
        do {
            try host.skimPauseEngine()
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
            host.skimBridgeState = state
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: true)
            let player = AVPlayer(url: plan.summaryAudioURL)
            self.player = player
            state.status = .playing
            host.skimBridgeState = state
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(host.skimMediaPlaybackRate))
            pollTask?.cancel()
            pollTask = Task { @MainActor [weak self, weak player] in
                while !Task.isCancelled {
                    guard let self, let host = self.host, let player, let item = player.currentItem else { return }
                    if item.status == .failed {
                        self.cancel(restoringOrigin: true, resumeSource: false)
                        host.skimWarn("The scene summary could not be played. Your original position was restored.")
                        return
                    }
                    let duration = CMTimeGetSeconds(item.duration)
                    let current = CMTimeGetSeconds(player.currentTime())
                    if duration.isFinite, duration > 0, current >= duration - 0.08 {
                        self.complete()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            host.skimSucceeded(plan.direction == .forward ? "Skimming forward." : "Skimming backward.")
        } catch {
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: false)
            host.skimFailed(error, context: "Skim failed")
        }
        #else
        host.skimWarn("Skim audio is unavailable on this device.")
        #endif
    }

    func complete() {
        guard let host, var bridge = host.skimBridgeState, host.skimHasEngine else { return }
        bridge.status = .completing
        host.skimBridgeState = bridge
        stopPlayback()
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        do {
            host.skimBridgeState = nil
            try host.skimSeekOrStage(toMediaTimeMs: bridge.destinationMediaTimeMs)
            if bridge.destinationSceneId == nil {
                try host.skimPauseEngine()
                host.skimConfirmed("Finished the final scene summary.")
            } else if bridge.wasSourcePlaying {
                try host.skimResumeEngine()
            } else {
                try host.skimPauseEngine()
            }
            host.skimBridgeDidFinish()
        } catch {
            cancel(restoringOrigin: true, resumeSource: false)
            host.skimFailed(error, context: "Completing Skim failed")
        }
    }

    func setPaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard let host, var bridge = host.skimBridgeState, let player = self.player else { return }
        if paused {
            player.pause()
            bridge.status = .paused
        } else {
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(host.skimMediaPlaybackRate))
            bridge.status = .playing
        }
        host.skimBridgeState = bridge
        #endif
    }

    /// The listener changed the listening speed while a summary plays.
    func setTransportRate(forPlaybackRate rate: Double) {
        #if canImport(AVFoundation)
        player?.rate = SummaryBridgeRatePolicy.transportRate(rate)
        #endif
    }

    func cancel(restoringOrigin: Bool, resumeSource: Bool) {
        guard let host, var bridge = host.skimBridgeState else { return }
        bridge.status = .cancelled
        stopPlayback()
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        host.skimBridgeState = nil
        guard restoringOrigin, host.skimHasEngine else { return }
        do { try host.skimSeekOrStage(toMediaTimeMs: bridge.originMediaTimeMs) } catch { host.skimEngineCallFailedWhileCancelling() }
        do {
            if resumeSource && bridge.wasSourcePlaying {
                try host.skimResumeEngine()
            } else {
                try host.skimPauseEngine()
            }
        } catch {
            host.skimEngineCallFailedWhileCancelling()
        }
    }

    func restoreOriginBeforeCanonicalTransport() {
        guard let bridge = host?.skimBridgeState else { return }
        cancel(restoringOrigin: true, resumeSource: bridge.wasSourcePlaying)
    }

    private func stopPlayback() {
        #if canImport(AVFoundation)
        player?.pause()
        player = nil
        pollTask?.cancel()
        pollTask = nil
        #endif
    }

    private func protectSummaryBridgeAsset(_ assetID: String, protected: Bool) {
        _ = try? host?.skimStore?.updateOwnedOfflineAsset(id: assetID) { asset in
            if protected {
                asset.protections.insert(.activeSummaryBridge)
            } else {
                asset.protections.remove(.activeSummaryBridge)
            }
        }
    }
}
