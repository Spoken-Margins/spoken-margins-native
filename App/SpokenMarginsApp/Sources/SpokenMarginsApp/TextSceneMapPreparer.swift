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
    func textSceneSummariesDidFinish(itemId: String, outcome: TextSceneSummaryOutcome)
}

/// How a run to summarise an article's or PDF's scenes began.
enum TextSceneSummaryStart: Equatable {
    case started
    case alreadyRunning
    /// The on-device model can't be used, so the item keeps its rule-based chapters. Carries the model's own reason.
    case modelUnavailable(String)

    /// A plain sentence to add after the chapters are made.
    var note: String {
        switch self {
        case .started: "Writing scene summaries on this device."
        case .alreadyRunning: "Scene summaries are still being written."
        case .modelUnavailable(let reason): "Scene summaries need the on-device model, so the chapters have no summaries. \(reason)."
        }
    }
}

/// How a run to summarise an article's or PDF's scenes ended.
enum TextSceneSummaryOutcome: Equatable {
    case summarised(scenes: Int, total: Int)
    /// The text has nothing the model can summarise (too short, or only headings).
    case nothingToSummarise
    /// The model ran but none of its summaries passed the grounding check.
    case noSummaryAccepted
    /// The listener already has another map for this text, which stays.
    case keptOtherMap
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .summarised(let scenes, let total): "Scene summaries are ready (\(scenes) of \(total) scenes). Skim can read them."
        case .nothingToSummarise: "This text is too short to summarise. The chapters stay as they are."
        case .noSummaryAccepted: "The on-device model's summaries didn't pass the check, so the chapters stay without summaries."
        case .keptOtherMap: "This item already has a Listening Map, so it was not replaced."
        case .cancelled: "Stopped writing scene summaries."
        case .failed(let reason): "Couldn't write scene summaries: \(reason)"
        }
    }

    var diagnostic: String {
        switch self {
        case .summarised(let scenes, let total): "summarised \(scenes) of \(total)"
        case .nothingToSummarise: "nothing_to_summarise"
        case .noSummaryAccepted: "no_summary_accepted"
        case .keptOtherMap: "kept_other_map"
        case .cancelled: "cancelled"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// On-device scene summaries for an article or a PDF (#3450): the text half of what `EpisodeMapPreparer` does for a
/// podcast. It plans scenes over the item's text (`TextSceneSummaryPlanner`), asks the model for each scene's label
/// through the shared `SceneSummaryLabeler`, saves one portable proposal placed by character, and renders the same
/// summary bridge audio. Skim already reads a proposal placed by character (#1471), so nothing else changes.
///
/// It fetches nothing: the text is the item's own. It runs on the listener's tap; the proposal is saved only when at
/// least one summary passed the check, so a device without the model keeps exactly the rule-based chapters.
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

    @discardableResult
    func prepare(itemId requestedItemId: String) -> TextSceneSummaryStart {
        guard let host, let store = host.store else { return .modelUnavailable("Nothing is open") }
        guard task == nil else { return .alreadyRunning }
        let client = host.localFoundationModelClient
        let availability = client.availability()
        guard availability.isAvailable else { return .modelUnavailable(availability.description) }
        let safeItem = host.safePodcastEvidenceComponent(requestedItemId)
        itemId = requestedItemId
        task = Task { [weak self] in
            let outcome: TextSceneSummaryOutcome
            do {
                outcome = try await Self.summarise(
                    itemId: requestedItemId, safeItemComponent: safeItem, store: store, client: client,
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
                outcome = .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.task = nil
            self.itemId = nil
            self.host?.textSceneSummariesDidFinish(itemId: requestedItemId, outcome: outcome)
        }
        return .started
    }

    /// The run itself. Reads and saves go off the main thread; only the model calls and the bridge renders await here.
    nonisolated static func summarise(
        itemId: String,
        safeItemComponent: String,
        store: SQLiteSessionStore,
        client: any LocalFoundationModelClient,
        renderBridge: @escaping @MainActor (PortableListeningMapScene, String) async throws -> Void
    ) async throws -> TextSceneSummaryOutcome {
        let loaded: LoadedText = try await Gate1AppModel.offMain {
            let item = try store.loadItem(id: itemId)
            let chapters = try store.loadListeningMap(itemId: itemId)?.chapters ?? []
            let others = try store.loadPortableListeningMapProposals(itemId: itemId)
                .contains { !TextSceneAssembly.isModelProposal($0) }
            return LoadedText(text: item.text ?? "", chapters: chapters, hasOtherMap: others)
        }
        if loaded.hasOtherMap { return .keptOtherMap }
        let drafts = TextSceneSummaryPlanner.plan(text: loaded.text, chapters: loaded.chapters)
        guard drafts.contains(where: \.isSummarizable) else { return .nothingToSummarise }

        let characters = Array(loaded.text)
        let labeler = SceneSummaryLabeler(client: client)
        var scenes: [PortableListeningMapScene] = []
        for draft in drafts {
            try Task.checkCancellation()
            let label = draft.isSummarizable
                ? await labeler.label(text: draft.modelText, chapterNumber: draft.order + 1)
                : nil
            scenes.append(TextSceneAssembly.scene(draft: draft, label: label, characters: characters))
        }
        let summarised = scenes.filter { $0.summaryText?.isEmpty == false }
        guard !summarised.isEmpty else { return .noSummaryAccepted }

        try Task.checkCancellation()
        let proposal = TextSceneAssembly.proposal(safeItemComponent: safeItemComponent, scenes: scenes)
        try await Gate1AppModel.offMain { try store.savePortableListeningMapProposal(proposal, itemId: itemId) }

        // Skim also prepares a summary's audio when it needs it, so one scene that fails to render is not a failed map.
        for scene in summarised {
            try Task.checkCancellation()
            do {
                try await renderBridge(scene, proposal.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return .summarised(scenes: summarised.count, total: scenes.count)
    }

    private struct LoadedText: Sendable {
        let text: String
        let chapters: [Chapter]
        let hasOtherMap: Bool
    }
}
