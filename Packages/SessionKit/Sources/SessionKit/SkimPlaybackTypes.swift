import Foundation

/// On a text item (#1471) the `...MediaTimeMs` fields below hold character offsets in the text, not milliseconds.
public struct ResolvedSkimPlaybackPlan {
    public let direction: SkimDirection
    public let itemId: String
    public let originMediaTimeMs: Int
    public let summarySceneId: String
    public let destinationSceneId: String?
    public let destinationMediaTimeMs: Int
    public let summaryAssetId: String
    public let summaryAudioURL: URL

    public init(
        direction: SkimDirection,
        itemId: String,
        originMediaTimeMs: Int,
        summarySceneId: String,
        destinationSceneId: String?,
        destinationMediaTimeMs: Int,
        summaryAssetId: String,
        summaryAudioURL: URL
    ) {
        self.direction = direction
        self.itemId = itemId
        self.originMediaTimeMs = originMediaTimeMs
        self.summarySceneId = summarySceneId
        self.destinationSceneId = destinationSceneId
        self.destinationMediaTimeMs = destinationMediaTimeMs
        self.summaryAssetId = summaryAssetId
        self.summaryAudioURL = summaryAudioURL
    }

    /// The same summary, landing at a chapter start instead of the scene start it lines up with (#569).
    public func landing(at mediaTimeMs: Int) -> ResolvedSkimPlaybackPlan {
        ResolvedSkimPlaybackPlan(
            direction: direction, itemId: itemId, originMediaTimeMs: originMediaTimeMs,
            summarySceneId: summarySceneId, destinationSceneId: destinationSceneId,
            destinationMediaTimeMs: mediaTimeMs, summaryAssetId: summaryAssetId, summaryAudioURL: summaryAudioURL
        )
    }
}

public struct SkimResourceContext: Sendable {
    public let itemId: String
    public let projection: ResolvedListeningMapProjection?
    public let proposal: PortableListeningMapProposalArtifact?
    public let assets: [OwnedOfflineAsset]
    /// Read for a text item (#1471): the map is the proposal alone, placed by character, with no media projection.
    public let usesTextPositions: Bool

    public init(
        itemId: String,
        projection: ResolvedListeningMapProjection?,
        proposal: PortableListeningMapProposalArtifact?,
        assets: [OwnedOfflineAsset],
        usesTextPositions: Bool
    ) {
        self.itemId = itemId
        self.projection = projection
        self.proposal = proposal
        self.assets = assets
        self.usesTextPositions = usesTextPositions
    }
}

extension SkimResourceContext {
    /// A resolved map and the proposal it places: the item has Skim, whether or not a scene can be skimmed from here.
    /// A text item's map is placed by the proposal's own character positions.
    public var hasMap: Bool { (usesTextPositions || projection != nil) && proposal?.scenes.isEmpty == false }
}

/// A scene whose summary has text but no saved audio in the current voice (#2185): Skim prepares it, then plays it.
public struct SkimSummaryRequest {
    public let itemId: String
    /// The id the summary's asset is saved under: the shared projection's for a friend's map, else the proposal's.
    public let proposalId: String
    /// The id the prepared summary is saved under, in the current voice.
    public let assetID: String
    public let scene: PortableListeningMapScene
    public let destinationMediaTimeMs: Int

    public init(
        itemId: String,
        proposalId: String,
        assetID: String,
        scene: PortableListeningMapScene,
        destinationMediaTimeMs: Int
    ) {
        self.itemId = itemId
        self.proposalId = proposalId
        self.assetID = assetID
        self.scene = scene
        self.destinationMediaTimeMs = destinationMediaTimeMs
    }
}

/// What a Skim from one place resolves to (#2185, `SkimReadiness`).
public enum SkimResolution {
    case ready(ResolvedSkimPlaybackPlan)
    case needsSummaryAudio(SkimSummaryRequest)
    case unavailable(SkimUnavailableReason)

    public var destinationMediaTimeMs: Int? {
        switch self {
        case .ready(let plan): return plan.destinationMediaTimeMs
        case .needsSummaryAudio(let request): return request.destinationMediaTimeMs
        case .unavailable: return nil
        }
    }

    public var unavailableReason: SkimUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
