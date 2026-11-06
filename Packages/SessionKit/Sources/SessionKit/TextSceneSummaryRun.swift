import Foundation

/// Where an article's or PDF's on-device scene summaries stand (#3461), read from the item's saved proposals alone so
/// the item screen can ask on every render without planning the text again.
public enum TextSceneSummaryProgress {
    public enum State: Equatable, Sendable {
        /// Not a text item (a podcast or other media), so this feature has nothing to say.
        case notApplicable
        /// No scene summaries were ever saved: never run, or every run stopped before one passed the check.
        case notStarted
        /// A run saved some scenes and stopped (cancel, heat, Low Power Mode, the app was killed), or the model
        /// had no accepted summary for some. Running again continues from there.
        case partial(decided: Int, total: Int)
        case complete
        /// A friend's map or another generator's proposal is saved; it stays and this device writes nothing beside it.
        case otherMap

        /// True when running again can add summaries.
        public var offersRun: Bool {
            switch self {
            case .notStarted, .partial: true
            case .notApplicable, .complete, .otherMap: false
            }
        }
    }

    /// A scene is decided when it holds a summary, or when it was judged not worth one (the model said so, or the
    /// scene is too short). An undecided scene is one the model has not answered for yet, or answered nothing that
    /// passed the check; a later run asks again.
    public static func isDecided(_ scene: PortableListeningMapScene) -> Bool {
        if let summary = scene.summaryText, !summary.isEmpty { return true }
        return scene.eligibility != .unknown
    }

    /// The id of the Listening Map a friend's text map is saved under (`SharedTextListeningMapImporter`).
    public static func sharedMapId(itemId: String) -> String { "shared-map-" + itemId }

    /// `friendsMapIsHere` is true when the item's Listening Map is a friend's. A proposal beside it is always theirs, even
    /// one an older build saved under this device's own generator, so it is never continued or written over.
    public static func state(proposals: [PortableListeningMapProposalArtifact], friendsMapIsHere: Bool = false) -> State {
        if friendsMapIsHere || proposals.contains(where: { !TextSceneAssembly.isModelProposal($0) }) { return .otherMap }
        guard let proposal = proposals.first(where: TextSceneAssembly.isModelProposal) else { return .notStarted }
        let decided = proposal.scenes.filter(isDecided).count
        return decided == proposal.scenes.count ? .complete : .partial(decided: decided, total: proposal.scenes.count)
    }
}

/// The loop that writes an article's or PDF's scene summaries, with everything that touches the device passed in so it
/// is host-tested (#3461). A run saves after every scene that gets a summary, so a cancel, a kill or a pause at scene N
/// keeps the first N-1 summaries; the next run carries them over and starts at the first scene still undecided.
public enum TextSceneSummaryRun {
    /// What the model gave for one scene.
    public enum SceneAnswer: Equatable, Sendable {
        case label(ListeningMapSummaryValidator.SceneLabel)
        /// The model answered and no try passed the grounding check. Asking again gets the same answer, so the scene is
        /// settled without a summary rather than offered again for good.
        case rejected
        /// Every call threw (the model was busy or not ready). Nothing is known about the scene, so it stays waiting.
        case modelFailed
    }

    public enum Ending: Equatable, Sendable {
        case finished
        /// The device asked the run to stop (heat, Low Power Mode). The summaries so far are saved.
        case paused(EpisodeMapRunStop)
        /// The model threw instead of answering. The run stops there, with what was decided saved, so the error is not
        /// mistaken for a verdict on every remaining scene.
        case modelFailed
        /// A friend's map arrived, or the chapters changed, while the run worked, so nothing more was saved.
        case otherMapAppeared
    }

    public struct Result: Equatable, Sendable {
        public let scenes: [PortableListeningMapScene]
        public let ending: Ending
        /// Summaries this run wrote, not counting the ones carried over.
        public let newSummaries: Int
        /// Scenes this run decided, with a summary or without (the model passed them over, or its answer failed the
        /// check). Zero means the run made no progress, however it ended.
        public let newDecisions: Int

        public var summarisedScenes: Int {
            scenes.filter { $0.summaryText?.isEmpty == false }.count
        }
    }

    /// The scenes a saved model proposal already settled, by scene id. A scene counts only if it still covers the same
    /// characters, so a proposal written for other chapters carries nothing over.
    public static func carriedScenes(
        drafts: [TextSceneDraft], saved: PortableListeningMapProposalArtifact?
    ) -> [String: PortableListeningMapScene] {
        guard let saved, TextSceneAssembly.isModelProposal(saved) else { return [:] }
        let byId = Dictionary(saved.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var carried: [String: PortableListeningMapScene] = [:]
        for draft in drafts {
            guard let scene = byId[draft.id],
                  scene.startAnchor.startChar == draft.startChar,
                  scene.endAnchor.endChar == draft.endChar,
                  TextSceneSummaryProgress.isDecided(scene) else { continue }
            carried[draft.id] = scene
        }
        return carried
    }

    /// Runs the drafts in order.
    /// - `label`: the model's answer for one scene's text.
    /// - `yieldReason`: nil to go on, or why the device wants the run to stop; asked before every scene.
    /// - `checkpoint`: saves the whole scene list so far; false means the item has another map now, which stays.
    ///   Called after each new summary, and once more at a pause or the end for what was decided without one.
    ///   Nothing is saved until a summary passed, so an item whose summaries all fail keeps exactly its chapters.
    ///
    /// Cancelling the task throws `CancellationError` at the next scene; every scene decided before that is saved.
    public static func run(
        drafts: [TextSceneDraft],
        characters: [Character],
        saved: PortableListeningMapProposalArtifact?,
        label: (TextSceneDraft) async -> SceneAnswer,
        yieldReason: @MainActor () -> EpisodeMapRunStop?,
        checkpoint: ([PortableListeningMapScene]) async throws -> Bool
    ) async throws -> Result {
        let carried = carriedScenes(drafts: drafts, saved: saved)
        var scenes = drafts.map { carried[$0.id] ?? TextSceneAssembly.scene(draft: $0, label: nil, characters: characters) }
        var written = 0
        var decided = 0
        var unsaved = false

        func settle(_ ending: Ending) async throws -> Result {
            if ending != .otherMapAppeared, unsaved, scenes.contains(where: { $0.summaryText?.isEmpty == false }) {
                guard try await checkpoint(scenes) else {
                    return Result(scenes: scenes, ending: .otherMapAppeared, newSummaries: written, newDecisions: decided)
                }
            }
            return Result(scenes: scenes, ending: ending, newSummaries: written, newDecisions: decided)
        }

        for (index, draft) in drafts.enumerated() where !TextSceneSummaryProgress.isDecided(scenes[index]) {
            if Task.isCancelled {
                // Keep what was decided without a summary since the last save, so the next run doesn't ask again.
                _ = try? await settle(.finished)
                throw CancellationError()
            }
            if let stop = await yieldReason() { return try await settle(.paused(stop)) }
            let scene: PortableListeningMapScene
            switch await label(draft) {
            case .label(let checked): scene = TextSceneAssembly.scene(draft: draft, label: checked, characters: characters)
            case .rejected: scene = TextSceneAssembly.scene(draft: draft, label: nil, characters: characters, rejectedByCheck: true)
            case .modelFailed: return try await settle(.modelFailed)
            }
            scenes[index] = scene
            decided += 1
            unsaved = true
            if scene.summaryText?.isEmpty == false {
                written += 1
                guard try await checkpoint(scenes) else { return Result(scenes: scenes, ending: .otherMapAppeared, newSummaries: written, newDecisions: decided) }
                unsaved = false
            }
        }
        return try await settle(.finished)
    }
}
