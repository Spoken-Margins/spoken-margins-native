import Foundation
import SessionKit

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

struct SkimResourceContext {
    let itemId: String
    let projection: ResolvedListeningMapProjection?
    let proposal: PortableListeningMapProposalArtifact?
    let assets: [OwnedOfflineAsset]
}
