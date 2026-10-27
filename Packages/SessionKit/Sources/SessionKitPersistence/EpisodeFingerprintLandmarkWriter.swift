import Foundation
import SessionKit

/// A fingerprint landmark just cut from the playing episode, as the writer needs it.
public struct EpisodeFingerprintLandmarkInput: Sendable {
    public let itemId: String
    public let sourceMediaStartMs: Int
    public let sourceMediaEndMs: Int
    public let anchorMediaTimeMs: Int
    public let continuityEpoch: Int
    public let gridIndex: Int?
    public let trigger: EpisodeFingerprintTrigger
    public let signatureData: Data

    public init(
        itemId: String,
        sourceMediaStartMs: Int,
        sourceMediaEndMs: Int,
        anchorMediaTimeMs: Int,
        continuityEpoch: Int,
        gridIndex: Int?,
        trigger: EpisodeFingerprintTrigger,
        signatureData: Data
    ) {
        self.itemId = itemId
        self.sourceMediaStartMs = sourceMediaStartMs
        self.sourceMediaEndMs = sourceMediaEndMs
        self.anchorMediaTimeMs = anchorMediaTimeMs
        self.continuityEpoch = continuityEpoch
        self.gridIndex = gridIndex
        self.trigger = trigger
        self.signatureData = signatureData
    }
}

/// Saves fingerprint landmarks to the episode's spine, off the main thread (#2781).
///
/// The save loads the stored spine, compacts it, writes the signature file, rewrites the spine record and saves the
/// offline-asset row. Its cost grows with the spine, and a spine Build 35 bloated (#2626) is compacted by the first
/// save, so on the main actor it froze the playback controls for seconds and, with the screen locked, let iOS end the
/// app (`0x8BADF00D`). An actor runs it away from the main thread. It also runs the saves one at a time: each reads the
/// spine and writes it back, so two landmarks cut close together (a grid point and a post-seek one) would otherwise
/// each write a spine without the other.
public actor EpisodeFingerprintLandmarkWriter {
    public struct Outcome: Equatable, Sendable {
        /// The new landmark is in the spine (false when compaction left it out as a repeat).
        public let keptNew: Bool
        /// Landmarks the save removed from the spine, with their signature files and offline-asset rows.
        public let removedCount: Int

        public init(keptNew: Bool, removedCount: Int) {
            self.keptNew = keptNew
            self.removedCount = removedCount
        }
    }

    private let store: SQLiteSessionStore
    /// `<applicationSupport>/SpokenMargins/EpisodeMaps`; each item gets a folder of its own below it.
    private let episodeMapsDirectory: URL

    public init(store: SQLiteSessionStore, episodeMapsDirectory: URL) {
        self.store = store
        self.episodeMapsDirectory = episodeMapsDirectory
    }

    @discardableResult
    public func write(_ capture: EpisodeFingerprintLandmarkInput) throws -> Outcome {
        let safeItem = PodcastAnchorEvidencePaths.safeComponent(capture.itemId)
        let root = episodeMapsDirectory.appending(path: safeItem, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suffix = capture.gridIndex.map { "grid-\($0)" }
            ?? "epoch-\(capture.continuityEpoch)-\(capture.sourceMediaStartMs)"
        let assetID = "episode-signature-\(safeItem)-\(suffix)"
        let fileURL = root.appending(path: "\(assetID).shazamsignature")

        let existing = try store.loadEditionFingerprintSpine(itemId: capture.itemId)
        let landmark = EpisodeFingerprintLandmark(
            id: "landmark-\(suffix)",
            order: 0,
            sourceMediaStartMs: capture.sourceMediaStartMs,
            sourceMediaEndMs: capture.sourceMediaEndMs,
            anchorMediaTimeMs: capture.anchorMediaTimeMs,
            continuityEpoch: capture.continuityEpoch,
            trigger: capture.trigger,
            provenance: .observedDecodedPlayback,
            signatureAssetId: assetID
        )
        // Build 35 kept cutting post-seek landmarks (#2626). The same rule trims what it left and refuses a repeat.
        let compacted = EpisodeFingerprintSpineCompaction.compact(existing: existing?.landmarks ?? [], adding: landmark)
        let keepsNew = compacted.keeps(signatureAssetId: assetID)
        let hadStoredNew = existing?.landmarks.contains { $0.signatureAssetId == assetID } ?? false
        let staleAssetIDs = compacted.dropped.map(\.signatureAssetId).filter { $0 != assetID || keepsNew || hadStoredNew }
        guard keepsNew || !staleAssetIDs.isEmpty else { return Outcome(keptNew: false, removedCount: 0) }
        if keepsNew { try capture.signatureData.write(to: fileURL, options: .atomic) }
        let item = try? store.loadItem(id: capture.itemId)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: existing?.id ?? "episode-spine-\(safeItem)",
            itemId: capture.itemId,
            canonicalURL: item?.externalReference ?? item?.media?.url,
            producingEditionDurationMs: item?.media?.durationMs,
            producingEditionSHA256: existing?.producingEditionSHA256,
            createdAt: existing?.createdAt ?? Date(),
            landmarks: compacted.kept
        ))
        if keepsNew {
            try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                id: assetID,
                itemId: capture.itemId,
                category: .fingerprintMap,
                relativePath: "SpokenMargins/EpisodeMaps/\(safeItem)/\(assetID).shazamsignature",
                byteCount: Int64(capture.signatureData.count),
                isReproducible: false
            ))
        }
        // The spine no longer holds these, so forget their rows and files. A failure here is not worth undoing the
        // save above; it leaves a stale file or row, as it did when this ran in the app.
        for staleID in staleAssetIDs {
            try? store.deleteOwnedOfflineAsset(id: staleID)
            try? FileManager.default.removeItem(at: root.appending(path: "\(staleID).shazamsignature"))
        }
        return Outcome(keptNew: keepsNew, removedCount: staleAssetIDs.count)
    }
}
