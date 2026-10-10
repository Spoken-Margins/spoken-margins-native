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
}

struct SkimResourceContext {
    let itemId: String
    let projection: ResolvedListeningMapProjection?
    let proposal: PortableListeningMapProposalArtifact?
    let assets: [OwnedOfflineAsset]
}
