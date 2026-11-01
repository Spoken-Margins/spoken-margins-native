import Foundation
import SessionKit

/// On a text item (#1471) the `...MediaTimeMs` fields below hold character offsets in the text, not milliseconds.
struct ResolvedSkimPlaybackPlan {
    let direction: SkimDirection
    let itemId: String
    let originMediaTimeMs: Int
    let summarySceneId: String
    let destinationSceneId: String?
    let destinationMediaTimeMs: Int
    let summaryAssetId: String
    let summaryAudioURL: URL

    /// The same summary, landing at a chapter start instead of the scene start it lines up with (#569).
    func landing(at mediaTimeMs: Int) -> ResolvedSkimPlaybackPlan {
        ResolvedSkimPlaybackPlan(
            direction: direction, itemId: itemId, originMediaTimeMs: originMediaTimeMs,
            summarySceneId: summarySceneId, destinationSceneId: destinationSceneId,
            destinationMediaTimeMs: mediaTimeMs, summaryAssetId: summaryAssetId, summaryAudioURL: summaryAudioURL
        )
    }
}

struct SkimResourceContext: Sendable {
    let itemId: String
    let projection: ResolvedListeningMapProjection?
    let proposal: PortableListeningMapProposalArtifact?
    let assets: [OwnedOfflineAsset]
    /// Read for a text item (#1471): the map is the proposal alone, placed by character, with no media projection.
    let usesTextPositions: Bool
}

extension SkimResourceContext {
    /// A resolved map and the proposal it places: the item has Skim, whether or not a scene can be skimmed from here.
    /// A text item's map is placed by the proposal's own character positions.
    var hasMap: Bool { (usesTextPositions || projection != nil) && proposal?.scenes.isEmpty == false }
}

/// A scene whose summary has text but no saved audio in the current voice (#2185): Skim prepares it, then plays it.
struct SkimSummaryRequest {
    let itemId: String
    /// The id the summary's asset is saved under: the shared projection's for a friend's map, else the proposal's.
    let proposalId: String
    /// The id the prepared summary is saved under, in the current voice.
    let assetID: String
    let scene: PortableListeningMapScene
    let destinationMediaTimeMs: Int
}

/// What a Skim from one place resolves to (#2185, `SkimReadiness`).
enum SkimResolution {
    case ready(ResolvedSkimPlaybackPlan)
    case needsSummaryAudio(SkimSummaryRequest)
    case unavailable(SkimUnavailableReason)

    var destinationMediaTimeMs: Int? {
        switch self {
        case .ready(let plan): return plan.destinationMediaTimeMs
        case .needsSummaryAudio(let request): return request.destinationMediaTimeMs
        case .unavailable: return nil
        }
    }

    var unavailableReason: SkimUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
