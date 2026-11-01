import Foundation

/// Places a friend's shared Listening Map on the recipient's own copy of an episode
/// when it is a different edition (other ads or encoding). Every scene start must be
/// placed by direct acoustic evidence, in increasing order, or the whole map stays
/// unused: a map with one scene in the wrong place would send Skim to the wrong audio.
///
/// This type holds the decision. `SharedListeningMapResolver` in SessionKitAudio runs
/// the acoustic matching. The portable proposal is never rewritten; the recipient's
/// times live only in the returned projection.
public enum SharedListeningMapPlacement {
    public static let algorithmVersion = "shared-map-scene-starts.v1"

    /// The projection id for a friend's map, one per imported packet. Friends sharing the
    /// same episode can send proposals with the same id, so the packet's layer is what
    /// tells their maps (and their summaries) apart.
    public static func projectionId(layerId: String) -> String {
        "imported-projection-\(layerId)"
    }

    /// Whether a stored projection places a friend's map. Its summaries are keyed by the
    /// projection id for the same reason the projection is.
    public static func isSharedProjection(id: String) -> Bool {
        id.hasPrefix(projectionId(layerId: ""))
    }

    /// The map a stored projection places, for the item's scene list and for Skim. A friend's
    /// map stays on its packet and is found by the packet's projection id; any other projection
    /// names its map by proposal id, among the listener's own maps first.
    public static func proposal(
        for projection: ResolvedListeningMapProjection?,
        committed: [PortableListeningMapProposalArtifact],
        layers: [ImportedCommentaryLayer]
    ) -> PortableListeningMapProposalArtifact? {
        if let projection, isSharedProjection(id: projection.id) {
            return layers.first { projectionId(layerId: $0.id) == projection.id }?.listeningMapProposals?.first
        }
        let proposals = committed + layers.flatMap { $0.listeningMapProposals ?? [] }
        return projection.flatMap { projection in proposals.first { $0.id == projection.proposalId } }
            ?? committed.first
    }

    /// The sender's scene starts must be present and increase even on an exact edition,
    /// where nothing is matched: Skim walks them in order.
    public static func startsRefusal(proposal: PortableListeningMapProposalArtifact) -> Refusal? {
        let scenes = proposal.scenes.sorted { $0.order < $1.order }
        guard !scenes.isEmpty else { return Refusal(sceneId: nil, sceneLabel: nil, reason: .noScenes) }
        var previous: Int?
        for scene in scenes {
            guard let start = scene.startAnchor.mediaTimeMs, start >= 0 else {
                return Refusal(sceneId: scene.id, sceneLabel: label(for: scene), reason: .missingStartTime)
            }
            if let previous, start <= previous {
                return Refusal(sceneId: scene.id, sceneLabel: label(for: scene), reason: .outOfOrder)
            }
            previous = start
        }
        return nil
    }

    /// One scene start and the sender's fingerprint landmarks that bracket it.
    public struct SceneQuery: Equatable, Sendable {
        public let sceneId: String
        public let senderStartMs: Int
        public let landmarks: [EpisodeFingerprintLandmark]

        public init(sceneId: String, senderStartMs: Int, landmarks: [EpisodeFingerprintLandmark]) {
            self.sceneId = sceneId
            self.senderStartMs = senderStartMs
            self.landmarks = landmarks
        }
    }

    public enum RefusalReason: String, Codable, Equatable, Sendable {
        case noScenes = "no_scenes"
        case missingStartTime = "missing_start_time"
        case noEvidence = "no_evidence"
        case unresolved
        case ambiguous
        case outOfOrder = "out_of_order"
        /// No landmark's audio covers the scene start, so nothing confirms where it starts.
        case uncovered
        /// Only one of the two landmarks around the scene start matched.
        case oneSideOnly = "one_side_only"
    }

    public struct Refusal: Error, Equatable, Sendable {
        /// The first scene that could not be placed; nil when the map has no scenes.
        public let sceneId: String?
        public let sceneLabel: String?
        public let reason: RefusalReason

        public init(sceneId: String?, sceneLabel: String?, reason: RefusalReason) {
            self.sceneId = sceneId
            self.sceneLabel = sceneLabel
            self.reason = reason
        }

        /// One plain sentence for the item's Advanced section.
        public var listenerReason: String {
            let scene = sceneLabel ?? "A scene"
            switch reason {
            case .noScenes: return "The shared map has no scenes."
            case .missingStartTime: return "\(scene) has no start time."
            case .noEvidence:
                return sceneLabel == nil
                    ? "The shared map came without the audio needed to match it to your copy."
                    : "The shared map has no audio to match near \(scene.lowercasedFirst)."
            case .unresolved: return "\(scene) wasn't found in your copy."
            case .ambiguous: return "\(scene) matched more than one place in your copy, or your copy changes inside it."
            case .outOfOrder: return "\(scene) landed before the scene ahead of it."
            case .oneSideOnly: return "Only part of the audio around \(scene.lowercasedFirst) matched your copy, so its start can't be confirmed."
            case .uncovered: return "The shared map has no audio at the start of \(scene.lowercasedFirst), so nothing confirms where it starts in your copy."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case placed(ResolvedListeningMapProjection)
        case notPlaced(Refusal)

        public var refusal: Refusal? {
            if case .notPlaced(let refusal) = self { return refusal }
            return nil
        }
    }

    /// Scenes in listening order, each with the landmarks that bracket its start:
    /// the last landmark starting at or before it and the first starting after it.
    /// Two flanks let the acoustic resolver notice a change between them; a scene
    /// before the first or after the last landmark has one.
    public static func sceneQueries(
        proposal: PortableListeningMapProposalArtifact,
        landmarks: [EpisodeFingerprintLandmark]
    ) -> Result<[SceneQuery], Refusal> {
        let scenes = proposal.scenes.sorted { $0.order < $1.order }
        guard !scenes.isEmpty else {
            return .failure(Refusal(sceneId: nil, sceneLabel: nil, reason: .noScenes))
        }
        var queries: [SceneQuery] = []
        for scene in scenes {
            guard let start = scene.startAnchor.mediaTimeMs, start >= 0 else {
                return .failure(Refusal(sceneId: scene.id, sceneLabel: label(for: scene), reason: .missingStartTime))
            }
            let bracket = bracketingLandmarks(around: start, in: landmarks)
            guard !bracket.isEmpty else {
                return .failure(Refusal(sceneId: scene.id, sceneLabel: label(for: scene), reason: .noEvidence))
            }
            queries.append(SceneQuery(sceneId: scene.id, senderStartMs: start, landmarks: bracket))
        }
        return .success(queries)
    }

    public static func bracketingLandmarks(
        around senderMs: Int,
        in landmarks: [EpisodeFingerprintLandmark]
    ) -> [EpisodeFingerprintLandmark] {
        let ordered = landmarks.sorted {
            $0.sourceMediaStartMs == $1.sourceMediaStartMs ? $0.id < $1.id : $0.sourceMediaStartMs < $1.sourceMediaStartMs
        }
        let before = ordered.last { $0.sourceMediaStartMs <= senderMs }
        let after = ordered.first { $0.sourceMediaStartMs > senderMs }
        return [before, after].compactMap { $0 }
    }

    /// A landmark signature matches where its window starts in the recipient's copy;
    /// the scene start is this far from there in the sender's edition.
    public static func anchorOffsetMs(sceneStartMs: Int, landmark: EpisodeFingerprintLandmark) -> Int {
        sceneStartMs - landmark.sourceMediaStartMs
    }

    /// Accepts the resolver's answers only when every scene start was placed by
    /// direct evidence and the starts increase; otherwise names the first failure.
    ///
    /// On a different edition a scene start is placed only when a matched landmark's own
    /// audio covers it. Matches away from the start, even on both sides, can't rule out an
    /// insertion and an equal cut between them that moves the start and neither landmark.
    /// The covering landmark must itself have matched, so a start between two landmarks needs
    /// both (a fused result): a single flank, even corroborated by neighbouring scenes, may be
    /// the far one while the covering passage was cut from the copy.
    /// A first scene that starts at 0:00 starts at 0:00 on any copy.
    public static func decide(
        proposal: PortableListeningMapProposalArtifact,
        queries: [SceneQuery],
        resolutions: [String: ImportedAnchorResolution],
        projectionId: String,
        itemId: String,
        recipientEditionSHA256: String?,
        createdAt: Date = Date()
    ) -> Outcome {
        let scenesById = Dictionary(proposal.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !queries.isEmpty else {
            return .notPlaced(Refusal(sceneId: nil, sceneLabel: nil, reason: .noScenes))
        }
        var points: [ResolvedListeningMapPoint] = []
        var previousStart: Int?
        for query in queries {
            let sceneLabel = scenesById[query.sceneId].map(label(for:))
            let resolution = resolutions[query.sceneId]
            guard let resolution, var placed = resolution.localMediaTimeMs, isDirectPlacement(resolution) else {
                let reason: RefusalReason = resolution?.isAmbiguous == true || resolution?.evidenceClass == .ambiguous
                    ? .ambiguous : .unresolved
                return .notPlaced(Refusal(sceneId: query.sceneId, sceneLabel: sceneLabel, reason: reason))
            }
            if resolution.evidenceClass != .exactEdition {
                if query.landmarks.count > 1, resolution.evidenceClass != .fused {
                    return .notPlaced(Refusal(sceneId: query.sceneId, sceneLabel: sceneLabel, reason: .oneSideOnly))
                }
                if query.senderStartMs == 0 {
                    placed = 0
                } else if !query.landmarks.contains(where: {
                    ($0.sourceMediaStartMs...$0.sourceMediaEndMs).contains(query.senderStartMs)
                }) {
                    return .notPlaced(Refusal(sceneId: query.sceneId, sceneLabel: sceneLabel, reason: .uncovered))
                }
            }
            if let previousStart, placed <= previousStart {
                return .notPlaced(Refusal(sceneId: query.sceneId, sceneLabel: sceneLabel, reason: .outOfOrder))
            }
            previousStart = placed
            points.append(ResolvedListeningMapPoint(
                id: "scene-start-\(query.sceneId)",
                sourceMediaTimeMs: query.senderStartMs,
                recipientMediaTimeMs: placed,
                confidence: .verified,
                evidenceIds: query.landmarks.map(\.signatureAssetId)
            ))
        }
        return .placed(ResolvedListeningMapProjection(
            id: projectionId,
            itemId: itemId,
            proposalId: proposal.id,
            recipientEditionSHA256: recipientEditionSHA256,
            createdAt: createdAt,
            algorithmVersion: algorithmVersion,
            points: points,
            intervals: []
        ))
    }

    public struct Activation: Equatable, Sendable {
        public let projection: ResolvedListeningMapProjection?
        public let refusal: Refusal?
    }

    /// What to save after resolving every friend's map on an item. A shared map never
    /// replaces one the listener already has: a map they prepared or imported for their
    /// own copy (a committed proposal) or the publisher's chapters. Among friends' maps, the one in use
    /// stays while it still places (matched by projection id, since friends' proposal ids can
    /// collide); otherwise the earliest imported that places wins, so
    /// a later packet doesn't swap the map under the listener. A refusal
    /// is reported only when no shared map is in use.
    /// - Parameters:
    ///   - outcomes: one per friend's map, in the order the packets were imported.
    ///   - activeProjectionId: the projection in use now, which stays while it still places.
    public static func activation(
        _ outcomes: [Outcome],
        listenerHasMap: Bool,
        activeProjectionId: String? = nil
    ) -> Activation {
        guard !listenerHasMap else { return Activation(projection: nil, refusal: nil) }
        let placed = outcomes.compactMap { outcome -> ResolvedListeningMapProjection? in
            if case .placed(let projection) = outcome { return projection }
            return nil
        }
        if let projection = placed.first(where: { $0.id == activeProjectionId }) ?? placed.first {
            return Activation(projection: projection, refusal: nil)
        }
        return Activation(projection: nil, refusal: outcomes.lazy.compactMap(\.refusal).first)
    }

    /// Whether the listener has a map a friend's never replaces: their own or the publisher's chapters. A community
    /// map never blocks a friend's (#553). Takes ids and a yes/no, so a caller reads neither the maps nor a timeline (#2506).
    public static func listenerHasMap(proposalIds: [String], hasTimelineChapters: Bool) -> Bool {
        proposalIds.contains { !CommunityMapConverter.isCommunityProposal(id: $0) } || hasTimelineChapters
    }

    /// The reason to show on the item, from what the last resolution stored on each packet:
    /// the earliest imported packet's, unless the listener now has a map of their own.
    public static func storedRefusalReason(layers: [ImportedCommentaryLayer], listenerHasMap: Bool) -> String? {
        guard !listenerHasMap else { return nil }
        return layers.filter { $0.deletedAt == nil }
            .sorted { $0.importedAt < $1.importedAt }
            .lazy.compactMap(\.sharedMapRefusalReason).first
    }

    static func isDirectPlacement(_ resolution: ImportedAnchorResolution) -> Bool {
        guard !resolution.isAmbiguous else { return false }
        switch resolution.evidenceClass {
        case .acousticVerified, .fused, .exactEdition:
            return true
        case .transcriptVerified, .articleTextVerified, .mapInterpolated, .timestampFallback,
             .recipientConfirmed, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    public static func label(for scene: PortableListeningMapScene) -> String {
        let title = scene.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Scene \(scene.order + 1)" : "Scene \(scene.order + 1) (\(title))"
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
