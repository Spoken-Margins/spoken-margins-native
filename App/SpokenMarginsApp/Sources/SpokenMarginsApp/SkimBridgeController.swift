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
    /// Nothing else holds the listener's ear (a Margin's voice, a friend's commentary, a recording), so a summary that
    /// finished preparing may start (#2185).
    var skimMayStartSummary: Bool { get }
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

    /// Prepares a scene's summary in the current voice and saves it as a verified summary asset; false when nothing
    /// was saved (#2185).
    func skimPrepareSummaryAudio(itemId: String, proposalId: String, scene: PortableListeningMapScene) async throws -> Bool
    /// One `skim.press` Diagnostics event: each press's outcome and why (#2185).
    func skimRecord(_ fields: [String: String])

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
    /// The playing item has a Listening Map, so its chapter row keeps the Skim controls even where neither can be
    /// pressed, and Next chapter in Skim's slot is drawn as standing in (#2185).
    private(set) var itemHasMap = false
    /// Why forward Skim can't be pressed from here, for the Next chapter that stands in for it (#2185).
    private(set) var forwardUnavailableReason: SkimUnavailableReason?
    #if DEBUG
    private(set) var resourceLoadCount = 0
    #endif

    private weak var host: (any SkimBridgeHost)?
    /// What Skim last loaded for an item. After a change to what it resolves against it stays, stale, until the
    /// reload lands, so the controls don't flicker off while the store is read (#2943).
    private var resourceContext: SkimResourceContext?
    private var resourcesAreStale = false
    /// Bumped by every invalidation, so a read that started before one is never installed as current.
    private var resourceGeneration = 0
    private var resourceLoad: (token: UUID, itemId: String, task: Task<Void, Never>)?
    private var isUpdatingAvailability = false
    /// A summary being prepared for a press (#2185). A press for the same summary meanwhile is told to wait; a press
    /// for another one replaces it, and the replaced result is ignored.
    private var summaryPreparation: (id: UUID, assetID: String, direction: SkimDirection, task: Task<Void, Never>)?
    /// The preparation whose audio is saved and whose resources are being reloaded: its timeout no longer applies (#2943).
    private var savedPreparationID: UUID?
    /// Summaries whose preparation failed in this voice: offered no more until the resources are refreshed, so a
    /// render that can't succeed isn't retried and re-advertised on every press (#2185).
    private var failedSummaryAssetIDs: Set<String> = []
    /// How long a press waits for a summary to be prepared before giving up on it.
    static let summaryPreparationTimeout: Duration = .seconds(30)
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

    /// The selected item was reassigned. Only a change to what Skim resolves against, on the item it loaded for,
    /// reloads the map and asset metadata (#2184): every reload used to, so each tap re-read them. Arriving at the
    /// loaded item counts as a change, so opening it reads them once. Explicit refreshes still reload them (#954).
    func itemDetailChanged(from old: SkimResourceKey, to new: SkimResourceKey) {
        guard old != new, resourceContext?.itemId == new.itemId || resourceLoad?.itemId == new.itemId else { return }
        invalidateResources()
    }

    private func invalidateResources() {
        resourceGeneration += 1
        resourcesAreStale = true
    }

    /// Returns once the resources being loaded have landed; for tests, which press right after a refresh.
    func settleResources() async {
        while let load = resourceLoad { await load.task.value }
    }

    /// A summary pass over `itemId` found these summary assets saved. Skim reloads its map and assets only when what it
    /// loaded for that item lacks one of them (#2255): every open used to reload them, on the main thread. Summaries
    /// that failed to prepare are offered again either way, as reopening the item always did.
    func summaryAssetsSaved(itemId: String, assetIDs: Set<String>) {
        failedSummaryAssetIDs = []
        if let context = resourceContext, context.itemId == itemId,
           !assetIDs.isSubset(of: Set(context.assets.lazy.filter { $0.integrity == .valid }.map(\.id))) {
            invalidateResources()
        } else if resourceLoad?.itemId == itemId {
            invalidateResources() // the first read may have started before these were saved (#2943)
        }
        updateAvailability(refreshResources: false)
    }

    func updateAvailability(refreshResources: Bool = true) {
        if refreshResources { invalidateResources(); failedSummaryAssetIDs = [] }
        guard !isUpdatingAvailability, let host else { return }
        let bridge = host.skimBridgeState
        let effectiveTime = bridge?.destinationMediaTimeMs ?? host.skimCurrentMediaTimeMs
        let forward = effectiveTime.map { resolve(direction: .forward, at: $0) }
        let backward = effectiveTime.map { resolve(direction: .backward, at: $0) }
        let forwardTime = bridge?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = bridge?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        let hasMap = host.skimSource.flatMap { loadedResources(for: $0) }?.hasMap ?? false
        let forwardReason = forward == nil ? .noSource : forward?.unavailableReason
        let destinationsChanged = forwardDestinationMs != forwardTime || backwardDestinationMs != backwardTime
            || itemHasMap != hasMap || forwardUnavailableReason != forwardReason
        if destinationsChanged {
            host.skimDestinationsWillChange()
            (forwardDestinationMs, backwardDestinationMs, itemHasMap) = (forwardTime, backwardTime, hasMap)
            forwardUnavailableReason = forwardReason
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

    /// A plan whose summary audio is saved and verified; nil otherwise. Next chapter's summary-first press uses this,
    /// so it never waits on a summary being prepared (#569).
    func resolvedPlan(direction: SkimDirection, at recipientMediaTimeMs: Int) -> ResolvedSkimPlaybackPlan? {
        if case .ready(let plan) = resolve(direction: direction, at: recipientMediaTimeMs) { return plan }
        return nil
    }

    /// The map, proposal and owned assets of the playing item, read once per item and map change (#2184). The read
    /// runs off the main actor (#2943): until it lands this is nil for an item not yet loaded, and the stale copy for
    /// one being reloaded. The controls and the press path ask on every tick and tap, so none of them may wait on the store.
    private func loadedResources(for source: SkimSource) -> SkimResourceContext? {
        guard host?.skimStore != nil else { return nil }
        if resourceContext?.itemId != source.itemId || resourcesAreStale { loadResources(itemId: source.itemId) }
        guard let context = resourceContext, context.itemId == source.itemId else { return nil }
        return context
    }

    /// Reads `itemId`'s resources off the main actor, installs them unless something invalidated them meanwhile
    /// (then reads again), and asks for another availability pass. One load runs per item at a time.
    private func loadResources(itemId: String) {
        if let load = resourceLoad, load.itemId == itemId { return }
        guard let store = host?.skimStore else { return }
        resourceLoad?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                let generation = self.resourceGeneration
                #if DEBUG
                self.resourceLoadCount += 1
                #endif
                let context = await Task.detached(priority: .userInitiated) {
                    Self.readResources(store: store, itemId: itemId)
                }.value
                guard self.resourceLoad?.token == token else { return }
                guard generation == self.resourceGeneration else { continue }
                self.resourceContext = context
                self.resourcesAreStale = false
                self.resourceLoad = nil
                self.updateAvailability(refreshResources: false)
                return
            }
        }
        resourceLoad = (token, itemId, task)
    }

    nonisolated private static func readResources(store: SQLiteSessionStore, itemId: String) -> SkimResourceContext {
        let projection = try? store.loadResolvedListeningMapProjection(itemId: itemId)
        return SkimResourceContext(
            itemId: itemId,
            projection: projection,
            proposal: SharedListeningMapPlacement.proposal(
                for: projection, committed: (try? store.loadPortableListeningMapProposals(itemId: itemId)) ?? [],
                layers: (try? store.loadImportedCommentaryLayers(itemId: itemId)) ?? []),
            assets: (try? store.loadOwnedOfflineAssets(itemId: itemId)) ?? []
        )
    }

    /// What a Skim from here does: play saved summary audio, prepare the summary first, or nothing, and why (#2185).
    func resolve(direction: SkimDirection, at recipientMediaTimeMs: Int) -> SkimResolution {
        guard let host, let source = host.skimSource else { return .unavailable(.noSource) }
        guard let resources = loadedResources(for: source) else {
            return .unavailable(host.skimStore == nil ? .noSource : .loading)
        }
        guard let projection = resources.projection, let proposal = resources.proposal else { return .unavailable(.noMap) }
        let plan = SceneStarts(scenes: proposal.scenes, projection: projection).skimPlan(
            direction: direction, at: recipientMediaTimeMs,
            durationMs: source.durationMs
        )
        let proposalId = SharedListeningMapPlacement.isSharedProjection(id: projection.id) ? projection.id : proposal.id
        let assetID = plan.map {
            host.summaryBridgeAssetID(
                itemId: source.itemId, proposalId: proposalId,
                sceneId: $0.summaryScene.id, suppliedAssetId: $0.summaryScene.summaryAssetId)
        }
        // A supplied voice imported before #1120 sits under the old cut name, so that name is tried after the new one.
        let legacyID = plan.flatMap { plan in
            plan.summaryScene.summaryAssetId.flatMap {
                SummaryBridgeAssetNaming.legacyAssetID(
                    itemId: source.itemId, proposalId: proposalId, sceneId: plan.summaryScene.id, suppliedAssetId: $0)
            }
        }
        let savedAsset = assetID.flatMap { assetID in
            ([assetID] + (legacyID.map { [$0] } ?? [])).lazy.compactMap { id in
                resources.assets.first(where: { $0.id == id && $0.category == .summaryBridge && $0.integrity == .valid })
            }.first
        }
        let url = savedAsset.flatMap { host.resolvedApplicationSupportAssetURL(for: $0.relativePath) }
        let readiness = SkimReadiness.of(
            hasMap: resources.hasMap, hasPlan: plan != nil, hasReadyAudio: url != nil,
            suppliesItsOwnVoice: plan?.summaryScene.summaryAssetId != nil)
        guard let plan, let assetID else { return .unavailable(readiness.unavailableReason ?? .noSceneSummary) }
        switch readiness {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .needsSummaryAudio:
            guard !failedSummaryAssetIDs.contains(assetID) else { return .unavailable(.preparationFailed) }
            return .needsSummaryAudio(SkimSummaryRequest(
                itemId: source.itemId, proposalId: proposalId, assetID: assetID,
                scene: plan.summaryScene, destinationMediaTimeMs: plan.destinationMediaTimeMs))
        case .ready:
            guard let url else { return .unavailable(.noSceneSummary) }
            return .ready(ResolvedSkimPlaybackPlan(
                direction: direction,
                itemId: source.itemId,
                originMediaTimeMs: recipientMediaTimeMs,
                summarySceneId: plan.summaryScene.id,
                destinationSceneId: plan.destinationSceneId,
                destinationMediaTimeMs: plan.destinationMediaTimeMs,
                summaryAssetId: savedAsset?.id ?? assetID,
                summaryAudioURL: url
            ))
        }
    }

    /// Every press logs one `skim.press` outcome with its reason (#2185); a press that prepares a summary logs a
    /// second line when that ends.
    func perform(direction: SkimDirection) {
        guard let host else { return }
        if host.skimBridgeState != nil {
            // A second tap exits the current bridge at its destination. Do not
            // resolve another summary against the asynchronous source seek.
            record(.completedBridge, direction)
            complete()
            return
        }
        let effectiveTime = host.skimCurrentMediaTimeMs ?? 0
        switch resolve(direction: direction, at: effectiveTime) {
        case .ready(let plan):
            play(plan)
        case .needsSummaryAudio(let request):
            prepareThenPlay(request, direction: direction)
        case .unavailable(let reason):
            record(.noPlan, direction, reason: reason.rawValue)
            host.skimWarn(reason.message)
        }
    }

    private func play(_ plan: ResolvedSkimPlaybackPlan) {
        start(plan)
        if host?.skimBridgeState != nil {
            record(.playedSummary, plan.direction)
        } else {
            record(.noAudio, plan.direction, reason: "not_started")
        }
    }

    /// The scene has a summary but no audio in the current voice: prepare it, then play it from where the listener
    /// is by then, if nothing has changed meanwhile (#2185). The source keeps playing while it is prepared.
    private func prepareThenPlay(_ request: SkimSummaryRequest, direction: SkimDirection) {
        guard let host else { return }
        if let pending = summaryPreparation {
            if pending.assetID == request.assetID {
                record(.alreadyPreparing, direction)
                host.skimSucceeded("Still preparing the scene summary.")
                return
            }
            pending.task.cancel()
            summaryPreparation = nil
            record(.noAudio, pending.direction, reason: SkimUnavailableReason.movedOn.rawValue, detail: "superseded")
        }
        record(.preparingSummary, direction, reason: "no_audio")
        host.skimSucceeded("Preparing the scene summary.")
        let id = UUID()
        let wasPlaying = host.skimSourceIsPlaying
        let task = Task { @MainActor [weak self] in
            var prepared = false
            var detail: String?
            do {
                guard let host = self?.host else { return }
                prepared = try await host.skimPrepareSummaryAudio(
                    itemId: request.itemId, proposalId: request.proposalId, scene: request.scene)
                if !prepared { detail = "nothing_saved" }
            } catch {
                detail = String(describing: error)
            }
            guard let self, self.summaryPreparation?.id == id else { return } // replaced or timed out: already logged
            // The new asset is in the store, not in what was loaded. The preparation stays registered while that is read,
            // so a press meanwhile is told to wait instead of preparing the same summary again.
            if prepared {
                self.savedPreparationID = id
                await self.reloadResources(itemId: request.itemId)
            }
            guard self.summaryPreparation?.id == id else { return }
            self.summaryPreparation = nil
            self.finishPreparation(request, direction: direction, wasPlaying: wasPlaying, prepared: prepared, detail: detail)
        }
        summaryPreparation = (id, request.assetID, direction, task)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.summaryPreparationTimeout)
            guard let self, let pending = self.summaryPreparation, pending.id == id, self.savedPreparationID != id else { return }
            pending.task.cancel()
            self.summaryPreparation = nil
            self.preparationFailed(request, direction: direction, detail: "timeout")
        }
    }

    /// Marks `itemId`'s resources stale, and reloads them and returns when they have landed (#2943) if it is the
    /// playing item. When it isn't (a recording is in progress, or another item plays), they are read when Skim next
    /// asks for that item; the audit found a summary saved meanwhile was otherwise never picked up.
    private func reloadResources(itemId: String) async {
        if resourceContext?.itemId == itemId || resourceLoad?.itemId == itemId { invalidateResources() }
        guard host?.skimSource?.itemId == itemId else { return }
        loadResources(itemId: itemId)
        await settleResources()
    }

    private func preparationFailed(_ request: SkimSummaryRequest, direction: SkimDirection, detail: String?) {
        failedSummaryAssetIDs.insert(request.assetID)
        record(.noAudio, direction, reason: SkimUnavailableReason.preparationFailed.rawValue, detail: detail)
        updateAvailability(refreshResources: false)
        host?.skimWarn(SkimUnavailableReason.preparationFailed.message)
    }

    private func finishPreparation(
        _ request: SkimSummaryRequest, direction: SkimDirection, wasPlaying: Bool, prepared: Bool, detail: String?
    ) {
        guard let host else { return }
        guard prepared else {
            preparationFailed(request, direction: direction, detail: detail)
            return
        }
        let resolution = resolve(direction: direction, at: host.skimCurrentMediaTimeMs ?? 0)
        // Why a summary that was prepared doesn't start now; nil when it may.
        let movedOn: String? = {
            if host.skimSource?.itemId != request.itemId { return "item_changed" }
            if host.skimBridgeState != nil { return "summary_playing" }
            if !host.skimMayStartSummary { return "margin_playing" }
            if host.skimSourceIsPlaying != wasPlaying { return wasPlaying ? "paused" : "resumed" }
            switch resolution {
            case .ready(let plan): return plan.summarySceneId == request.scene.id ? nil : "scene_changed"
            case .needsSummaryAudio(let next): return next.scene.id == request.scene.id ? "voice_changed" : "scene_changed"
            case .unavailable: return "scene_changed"
            }
        }()
        if case .ready(let plan) = resolution, movedOn == nil {
            play(plan)
            return
        }
        let why = movedOn ?? "scene_changed"
        record(.noAudio, direction, reason: SkimUnavailableReason.movedOn.rawValue, detail: why)
        updateAvailability(refreshResources: false)
        // Another item, a Margin's voice or the listener's own pause is its own answer; otherwise say why.
        if why == "scene_changed" || why == "voice_changed" { host.skimWarn(SkimUnavailableReason.movedOn.message) }
    }

    private func record(_ outcome: SkimPressOutcome, _ direction: SkimDirection, reason: String? = nil, detail: String? = nil) {
        var fields = outcome.diagnosticFields(direction: direction, reason: reason)
        if let detail { fields["detail"] = String(detail.prefix(160)) }
        host?.skimRecord(fields)
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
