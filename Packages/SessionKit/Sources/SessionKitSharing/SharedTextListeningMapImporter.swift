import Foundation
import SessionKit

/// Puts a shared Listening Map on the article or PDF the listener already has (#1471).
///
/// The map is placed by the quotations in the packet, never by the sender's offsets alone. What is saved is the
/// listener's own: a Listening Map whose chapters point into their text, and the shared proposal with its scenes
/// re-anchored to that text so each chapter's summary stays with it. Nothing here touches Margins or playback.
public enum SharedTextListeningMapImporter {
    /// What the item holds now, compared with the map being imported.
    public enum Existing: Equatable, Sendable {
        /// No shared or generated map: only the headings the app found, or nothing.
        case none
        /// This same map was added before.
        case sameMap(chapterCount: Int)
        /// Another map the listener has is saved for this item: one shared earlier, one they generated or pasted in,
        /// or one from a Listening Edition. Importing replaces it.
        case differentMap
    }

    public enum Outcome: Equatable, Sendable {
        case added(placed: Int, total: Int, replacedAnotherMap: Bool)
        case alreadyAdded(chapterCount: Int)

        /// The listener-facing line.
        public var message: String {
            switch self {
            case .alreadyAdded(let count):
                return "This Listening Map is already on your copy (\(Self.chapters(count))). Playback has not started."
            case .added(let placed, let total, _):
                if placed == total { return "Added the Listening Map: \(Self.chapters(placed)). Playback has not started." }
                return "Added \(placed) of \(total) chapters. The rest weren't found in your copy. Playback has not started."
            }
        }

        private static func chapters(_ count: Int) -> String { count == 1 ? "1 chapter" : "\(count) chapters" }
    }

    public static func existing(
        for proposal: PortableListeningMapProposalArtifact,
        itemId: String,
        repository: SessionRepository
    ) throws -> Existing {
        let stored = try repository.loadPortableListeningMapProposals(itemId: itemId)
        if let same = stored.first(where: { $0.id == proposal.id }) { return .sameMap(chapterCount: same.scenes.count) }
        if !stored.isEmpty { return .differentMap }
        // A map the listener made or pasted in is saved only as a Listening Map, with no proposal beside it. Saving a
        // new map deletes it, so the sheet has to say "Replace" before that happens.
        if let map = try repository.loadListeningMap(itemId: itemId), !isAppDerived(map, itemId: itemId) { return .differentMap }
        return .none
    }

    /// Chapters the app found by itself, from headings or the document's own navigation. They can be found again, so
    /// replacing them costs the listener nothing. Any other map was made, pasted or shared, and replacing it loses it.
    static func isAppDerived(_ map: ListeningMap, itemId: String) -> Bool {
        map.id == "shared-map-" + itemId
            || map.id.hasPrefix("canonical-navigation-")
            || map.id == "map-\(itemId)-markdown"
            || map.id == "map-\(itemId)-generated"
    }

    /// A map placed on an item, ready to save. Building it only reads the repository, so it can run off the main actor.
    public struct Plan: Sendable {
        let proposal: PortableListeningMapProposalArtifact
        let placement: TextListeningMapPlacement
        public let existing: Existing

        public var isAlreadyThere: Bool { if case .sameMap = existing { return true } else { return false } }
    }

    /// Places the packet's map on `item`. Throws `shared_map_not_found_in_item` when fewer than half the chapters are
    /// found, because a map that mostly misses would mislead Skim more than it helped.
    public static func plan(
        _ contents: VerifiedSpokenMarginsPackage,
        for item: Item,
        repository: SessionRepository
    ) throws -> Plan {
        guard let proposal = ListeningMapPacket.proposal(in: contents) else {
            throw SessionKitError.persistenceFailed("shared_map_is_unavailable")
        }
        let existing = try existing(for: proposal, itemId: item.id, repository: repository)
        if case .sameMap = existing {
            return Plan(proposal: proposal, placement: TextListeningMapPlacement(proposalId: proposal.id, scenes: [], unplacedSceneIds: []), existing: existing)
        }
        guard let text = item.text, !text.isEmpty else {
            throw SessionKitError.persistenceFailed("shared_map_not_found_in_item")
        }
        let placement = TextListeningMapPlacer.place(
            proposal, in: text, expectedExactEditionSHA256: contents.manifest.item.exactEditionSHA256
        )
        guard placement.isUsable else { throw SessionKitError.persistenceFailed("shared_map_not_found_in_item") }
        return Plan(proposal: proposal, placement: placement, existing: existing)
    }

    /// Saves a plan. `attach` saves the finished Listening Map; the app passes one that also tells a running session,
    /// and may refuse (a map can't change under playback). It runs before the proposal is saved, so a refusal leaves
    /// nothing behind and the same import can be tried again. The default writes straight to the repository.
    public static func commit(
        _ plan: Plan,
        to item: Item,
        senderLabel: String? = nil,
        repository: SessionRepository,
        attach: ((ListeningMap) throws -> Void)? = nil
    ) throws -> Outcome {
        guard let map = mapToAttach(plan, to: item, senderLabel: senderLabel) else {
            return outcome(of: plan)
        }
        if let attach { try attach(map) } else { try repository.saveListeningMap(map) }
        return try saveProposal(plan, to: item, repository: repository)
    }

    // The two halves of `commit`, for a caller that must attach the map where a running session lives (the main
    // actor) but can save the proposal rows anywhere (#2509): `mapToAttach` is pure, the app attaches it, then
    // `saveProposal` runs off the main actor. Run in that order, they do what `commit` does.

    /// The Listening Map to attach, or nil when this exact map is already on the item (nothing to save).
    public static func mapToAttach(_ plan: Plan, to item: Item, senderLabel: String? = nil) -> ListeningMap? {
        if case .sameMap = plan.existing { return nil }
        let overview = senderLabel.map { "Chapters shared by \($0)." } ?? "Chapters shared with you."
        return ListeningMap(id: "shared-map-" + item.id, itemId: item.id, overview: overview, chapters: plan.placement.chapters)
    }

    /// Saves the shared proposal beside an attached map and returns the outcome. A map that replaces another leaves
    /// only itself, so the item never reads the old one. The two writes are one ordered step on one thread.
    public static func saveProposal(_ plan: Plan, to item: Item, repository: SessionRepository) throws -> Outcome {
        if case .sameMap = plan.existing { return outcome(of: plan) }
        try repository.removePortableListeningMapProposals(itemId: item.id)
        try repository.savePortableListeningMapProposal(localProposal(from: plan.proposal, placement: plan.placement), itemId: item.id)
        return outcome(of: plan)
    }

    /// What committing `plan` reports; for a plan that is already there, it is known without touching the store.
    public static func outcome(of plan: Plan) -> Outcome {
        if case .sameMap(let count) = plan.existing { return .alreadyAdded(chapterCount: count) }
        return .added(placed: plan.placement.scenes.count, total: plan.placement.totalSceneCount, replacedAnotherMap: plan.existing == .differentMap)
    }

    public static func importMap(
        _ contents: VerifiedSpokenMarginsPackage,
        into item: Item,
        senderLabel: String? = nil,
        repository: SessionRepository,
        attach: ((ListeningMap) throws -> Void)? = nil
    ) throws -> Outcome {
        try commit(try plan(contents, for: item, repository: repository), to: item, senderLabel: senderLabel, repository: repository, attach: attach)
    }

    /// The shared proposal as this listener's copy of it: only the placed scenes, in order, each with its start and
    /// end offsets in the listener's text. The ids stay the sender's, so a second import of the same map is seen.
    static func localProposal(
        from proposal: PortableListeningMapProposalArtifact,
        placement: TextListeningMapPlacement
    ) -> PortableListeningMapProposalArtifact {
        let original = Dictionary(proposal.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scenes = placement.scenes.enumerated().compactMap { position, placed -> PortableListeningMapScene? in
            guard let scene = original[placed.id] else { return nil }
            return PortableListeningMapScene(
                id: scene.id, order: position, title: scene.title,
                summaryText: scene.summaryText, summaryProvenance: scene.summaryProvenance,
                eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                startAnchor: located(scene.startAnchor, startChar: placed.startChar, endChar: placed.startChar + max(1, scene.startAnchor.exactText?.count ?? 1)),
                endAnchor: located(scene.endAnchor, startChar: max(placed.startChar, placed.endChar - max(1, scene.endAnchor.exactText?.count ?? 1)), endChar: placed.endChar)
            )
        }
        return PortableListeningMapProposalArtifact(
            id: proposal.id, languageCode: proposal.languageCode, createdAt: proposal.createdAt,
            generator: proposal.generator, scenes: scenes
        )
    }

    private static func located(_ anchor: PortableAnchorEvidence, startChar: Int, endChar: Int) -> PortableAnchorEvidence {
        PortableAnchorEvidence(
            anchorType: anchor.anchorType, startChar: startChar, endChar: endChar,
            exactText: anchor.exactText, prefix: anchor.prefix, suffix: anchor.suffix
        )
    }
}
