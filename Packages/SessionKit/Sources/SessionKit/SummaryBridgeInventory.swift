import Foundation

/// What a pass over a Listening Map's summary audio starts from (#2255): the map's proposal and the summary assets
/// already saved, read once. Opening a mapped item used to read the whole owned-asset table once per scene, and reload
/// Skim's map and assets after each one, all on the main thread, even when every summary was already saved. On the
/// owner's phone that froze a 77-minute episode for 20 s on open, and 9.5 s on reopen. `read` is meant to run off
/// the main thread; `scenesNeedingAudio` does no store reads.
public struct SummaryBridgeInventory: Sendable {
    public let proposal: PortableListeningMapProposalArtifact
    /// The relative path of each valid saved asset, by asset ID.
    private let savedPaths: [String: String]

    public init(proposal: PortableListeningMapProposalArtifact, assets: [OwnedOfflineAsset]) {
        self.proposal = proposal
        var paths: [String: String] = [:]
        for asset in assets where asset.integrity == .valid && paths[asset.id] == nil {
            paths[asset.id] = asset.relativePath
        }
        savedPaths = paths
    }

    /// The inventory for an item, or nil when it has no placed map. The asset table is read at most once, and only
    /// when the map has an eligible scene.
    public static func read(
        loadProposal: () throws -> PortableListeningMapProposalArtifact?,
        loadAssets: () throws -> [OwnedOfflineAsset]
    ) throws -> SummaryBridgeInventory? {
        guard let proposal = try loadProposal() else { return nil }
        let needsAssets = proposal.scenes.contains { $0.eligibility == .eligible }
        return SummaryBridgeInventory(proposal: proposal, assets: needsAssets ? try loadAssets() : [])
    }

    /// The eligible scenes whose summary audio isn't saved, in map order. A scene with no summary text stays in the
    /// list, so the pass still reports it as not prepared.
    public func scenesNeedingAudio(
        assetID: (PortableListeningMapScene) -> String,
        fileExists: (String) -> Bool
    ) -> [PortableListeningMapScene] {
        proposal.scenes.filter { scene in
            guard scene.eligibility == .eligible else { return false }
            guard scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let path = savedPaths[assetID(scene)] else { return true }
            return !fileExists(path)
        }
    }
}
