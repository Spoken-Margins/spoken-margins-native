import Foundation
import SessionKit
import SessionKitPersistence

/// What `TextSceneMapPreparer` needs from the model that owns it. The preparer holds its host weakly.
@MainActor
protocol TextSceneMapPreparerHost: AnyObject {
    var store: SQLiteSessionStore? { get }
    var localFoundationModelClient: any LocalFoundationModelClient { get }
    func safePodcastEvidenceComponent(_ value: String) -> String
    /// The summary bridge audio for one scene: the same step a podcast's scenes use.
    func prepareSummaryBridgeAsset(
        itemId: String,
        proposalId: String,
        scene: PortableListeningMapScene,
        store: SQLiteSessionStore
    ) async throws -> OwnedOfflineAsset?
    /// Heat and Low Power Mode, asked before every scene (#3461). The model already answers this for podcast maps.
    func episodeMapDeviceConditions() -> SpeechEngineConditions
    /// `progressed` is true when the run saved at least one scene (a summary, or scenes it decided beside one), however
    /// it ended; scenes decided but never saved are not progress, since the next run would ask about them again.
    func textSceneSummariesDidFinish(
        itemId: String, outcome: TextSceneSummaryOutcome, policy: PreparationJobPolicy, progressed: Bool
    )
}

/// Counts the saves a run made. A cancelled run throws, so what it saved is read from here, not from its result.
private final class TextSceneSaveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    func add() { lock.lock(); saves += 1; lock.unlock() }
    var hasSaved: Bool { lock.lock(); defer { lock.unlock() }; return saves > 0 }
}

/// On-device scene summaries for an article or a PDF (#3450): the text half of what `EpisodeMapPreparer` does for a
/// podcast. It plans scenes over the item's text (`TextSceneSummaryPlanner`), asks the model for each scene's label
/// through the shared `SceneSummaryLabeler`, saves one portable proposal placed by character, and renders the same
/// summary bridge audio. Skim already reads a proposal placed by character (#1471), so nothing else changes.
///
/// It fetches nothing: the text is the item's own. It runs on the listener's tap or, with While Charging on, in the
/// background pass. The proposal is saved after every scene that gets a summary and only once one passed the check, so a
/// cancel, a pause or a killed app keeps what was written, a device without the model keeps exactly the rule-based
/// chapters, and the next run continues at the first scene still undecided (#3461).
@MainActor
final class TextSceneMapPreparer {
    private(set) var task: Task<Void, Never>?
    private(set) var itemId: String?
    private weak var host: (any TextSceneMapPreparerHost)?

    init(host: any TextSceneMapPreparerHost) {
        self.host = host
    }

    func cancel(itemId: String) {
        if self.itemId == itemId { task?.cancel() }
    }


    /// `policy` is `.explicit` for the listener's tap and `.whileCharging` for the background pass, which Low Power
    /// Mode stops (`EpisodeMapRunGuard`); heat stops both.
    @discardableResult
    func prepare(itemId requestedItemId: String, policy: PreparationJobPolicy = .explicit) -> TextSceneSummaryStart {
        guard let host, let store = host.store else { return .modelUnavailable("Nothing is open") }
        guard task == nil else { return self.itemId == requestedItemId ? .alreadyRunning : .busyWithAnotherItem }
        let client = host.localFoundationModelClient
        let availability = client.availability()
        guard availability.isAvailable else { return .modelUnavailable(availability.description) }
        let safeItem = host.safePodcastEvidenceComponent(requestedItemId)
        itemId = requestedItemId
        task = Task { [weak self] in
            let outcome: TextSceneSummaryOutcome
            let saves = TextSceneSaveCount()
            do {
                outcome = try await Self.summarise(
                    itemId: requestedItemId, safeItemComponent: safeItem, store: store, client: client,
                    onSaved: { saves.add() },
                    yieldReason: { [weak self] in
                        guard let host = self?.host else { return nil }
                        return EpisodeMapRunGuard.yieldReason(conditions: host.episodeMapDeviceConditions(), policy: policy)
                    },
                    renderBridge: { scene, proposalId in
                        guard let host = self?.host else { return }
                        _ = try await host.prepareSummaryBridgeAsset(
                            itemId: requestedItemId, proposalId: proposalId, scene: scene, store: store
                        )
                    }
                )
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(ListenerErrorText.message(for: error))
            }
            guard let self else { return }
            self.task = nil
            self.itemId = nil
            self.host?.textSceneSummariesDidFinish(
                itemId: requestedItemId, outcome: outcome, policy: policy, progressed: saves.hasSaved
            )
        }
        return .started
    }

    /// The run itself. Reads and saves go off the main thread; only the model calls and the bridge renders await here.
    nonisolated static func summarise(
        itemId: String,
        safeItemComponent: String,
        store: SQLiteSessionStore,
        client: any LocalFoundationModelClient,
        onSaved: @escaping @Sendable () -> Void = {},
        yieldReason: @escaping @MainActor () -> EpisodeMapRunStop? = { nil },
        renderBridge: @escaping @MainActor (PortableListeningMapScene, String) async throws -> Void
    ) async throws -> TextSceneSummaryOutcome {
        let loaded: LoadedText = try await Gate1AppModel.offMain {
            let item = try store.loadItem(id: itemId)
            let map = try store.loadListeningMap(itemId: itemId)
            let chapters = map?.chapters ?? []
            let proposals = try store.loadPortableListeningMapProposals(itemId: itemId)
            return LoadedText(
                text: item.text ?? "", chapters: chapters,
                // A friend's map stays whatever generator its proposal carries (an older build kept the sender's).
                hasOtherMap: map?.id == TextSceneSummaryProgress.sharedMapId(itemId: itemId)
                    || proposals.contains { !TextSceneAssembly.isModelProposal($0) },
                saved: proposals.first(where: TextSceneAssembly.isModelProposal)
            )
        }
        if loaded.hasOtherMap { return .keptOtherMap }
        let drafts = TextSceneSummaryPlanner.plan(text: loaded.text, chapters: loaded.chapters)
        guard drafts.contains(where: \.isSummarizable) else { return .nothingToSummarise }

        let labeler = SceneSummaryLabeler(client: client)
        let plannedStarts = loaded.chapters.map(\.startChar)
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts,
            characters: Array(loaded.text),
            saved: loaded.saved,
            label: { await labeler.answer(text: $0.modelText, chapterNumber: $0.order + 1) },
            yieldReason: yieldReason,
            checkpoint: { scenes in
                let proposal = TextSceneAssembly.proposal(safeItemComponent: safeItemComponent, scenes: scenes)
                // The run takes minutes. If a friend's map was imported meanwhile, it replaced the chapters these scenes
                // were planned on, so saving now would put out-of-date scenes beside it and Skim would read the wrong ones.
                return try await Gate1AppModel.offMain { () throws -> Bool in
                    let others = try store.loadPortableListeningMapProposals(itemId: itemId)
                        .contains { !TextSceneAssembly.isModelProposal($0) }
                    let starts = try store.loadListeningMap(itemId: itemId)?.chapters.map(\.startChar) ?? []
                    guard !others, starts == plannedStarts else { return false }
                    try store.savePortableListeningMapProposal(proposal, itemId: itemId)
                    onSaved()
                    return true
                }
            }
        )
        // A cancel makes the model call throw, which the run reads as a model failure; it is a cancel.
        try Task.checkCancellation()
        switch result.ending {
        case .otherMapAppeared:
            return .keptOtherMap
        case .modelFailed:
            return .modelStopped(written: result.summarisedScenes, total: result.scenes.count)
        case .paused(let stop):
            return .paused(stop, written: result.summarisedScenes, total: result.scenes.count)
        case .finished:
            guard result.summarisedScenes > 0 else { return .noSummaryAccepted }
        }

        // Skim also prepares a summary's audio when it needs it, so one scene that fails to render is not a failed map.
        let proposalId = TextSceneAssembly.proposalId(safeItemComponent: safeItemComponent)
        for scene in result.scenes where scene.summaryText?.isEmpty == false {
            try Task.checkCancellation()
            // Speaking the summaries is the hot part, so heat and Low Power Mode stop it too; Skim renders what is missing later.
            if let stop = await yieldReason() { return .audioPaused(stop) }
            do {
                try await renderBridge(scene, proposalId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return .summarised(scenes: result.summarisedScenes, total: result.scenes.count)
    }

    private struct LoadedText: Sendable {
        let text: String
        let chapters: [Chapter]
        let hasOtherMap: Bool
        /// The model proposal an earlier run saved, to continue from.
        let saved: PortableListeningMapProposalArtifact?
    }
}
