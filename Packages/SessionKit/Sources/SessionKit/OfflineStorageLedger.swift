#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum OfflineStorageLedgerError: Error, LocalizedError, Equatable {
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case missingReservation
    case reservationExceeded(reservedBytes: Int64, actualBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            return "Offline storage needs \(required) bytes, but only \(available) bytes are safely available."
        case .missingReservation:
            return "The offline storage reservation is missing or expired."
        case .reservationExceeded(let reserved, let actual):
            return "The offline write produced \(actual) bytes after reserving only \(reserved) bytes."
        }
    }
}

/// The rendered-speech cache as the ledger sees it: something it can empty (#313). The cache manages its own
/// size outside the ledger, so Clear Audio asks the open cache to empty itself.
public protocol RenderedSpeechCacheClearing: AnyObject, Sendable {
    /// Deletes every cached file and returns the bytes freed.
    func removeAll() -> Int64
}

public actor OfflineStorageLedger {
    private let repository: any SessionRepository
    private let rootDirectory: URL
    private let fileManager: FileManager
    /// The last reconciliation's counts, for diagnostics (#259).
    public private(set) var lastReconciliation: OfflineLedgerReconciliation?
    /// The render signature prepared chunks are current for; the rest are stale (#281).
    private var currentPreparedChunkDigest: String?
    /// Files a writer still has to read, as paths under the root, by the reservation it holds (#645):
    /// a prepared article's committed chunks while its next chunk renders or while they're assembled.
    /// Eviction skips them until that reservation is committed, released or expires. By path, so a
    /// row adopted for the same file is spared too. Kept in memory only: a relaunch ends every writer.
    private var pinnedPaths: [String: Set<String>] = [:]

    public init(repository: any SessionRepository, rootDirectory: URL, fileManager: FileManager = .default) {
        self.repository = repository
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    /// `pinning` names files (paths under the root) the writer reads before it commits. They're
    /// never evicted to make room, for this reservation or any other, while it's held; if the room
    /// can't be found elsewhere the reservation is refused and the files stay (#645).
    public func reserve(
        ownerId: String, byteCount: Int64, lifetime: TimeInterval = 60 * 60, pinning: Set<String> = []
    ) throws -> OfflineStorageReservation {
        let now = Date()
        for expired in try repository.loadOfflineStorageReservations() where expired.expiresAt <= now {
            try repository.deleteOfflineStorageReservation(id: expired.id)
            pinnedPaths[expired.id] = nil
        }
        let budget = try repository.loadOfflineStorageBudget()
        var assets = try repository.loadOwnedOfflineAssets()
        let reservations = try repository.loadOfflineStorageReservations()
        var used = OfflineStoragePlanner.usageBytes(assets: assets, reservations: reservations, now: now)
        let requested = max(0, byteCount)
        var deficit = max(0, used + requested - budget.limitBytes)
        if deficit > 0 {
            // Charges for files that no longer exist must not evict real audio or refuse the
            // request (#259). Reconcile before planning any eviction.
            if !(try reconcileWithDisk()).isEmpty {
                assets = try repository.loadOwnedOfflineAssets()
                used = OfflineStoragePlanner.usageBytes(assets: assets, reservations: reservations, now: now)
                deficit = max(0, used + requested - budget.limitBytes)
            }
        }
        if deficit > 0 {
            var (plan, references) = try evictionPlan(requiredBytes: deficit, assets: assets, alsoPinning: pinning)
            guard plan.reclaimableBytes >= deficit else {
                throw OfflineStorageLedgerError.insufficientSpace(
                    requiredBytes: requested,
                    availableBytes: max(0, budget.limitBytes - used + plan.reclaimableBytes)
                )
            }
            let reclaimed = try execute(plan: plan, assets: assets, references: &references)
            guard reclaimed >= deficit else {
                throw OfflineStorageLedgerError.insufficientSpace(
                    requiredBytes: requested,
                    availableBytes: max(0, budget.limitBytes - used + reclaimed)
                )
            }
        }
        if let physicalAvailable = physicallyAvailableBytes(),
           physicalAvailable >= 0,
           requested > physicalAvailable {
            throw OfflineStorageLedgerError.insufficientSpace(
                requiredBytes: requested,
                availableBytes: physicalAvailable
            )
        }
        let reservation = OfflineStorageReservation(
            id: "reservation-\(UUID().uuidString)",
            ownerId: ownerId,
            byteCount: requested,
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        try repository.saveOfflineStorageReservation(reservation)
        if !pinning.isEmpty { pinnedPaths[reservation.id] = pinning }
        return reservation
    }

    public func commit(reservationId: String, asset: OwnedOfflineAsset) throws {
        guard let reservation = try repository.loadOfflineStorageReservations().first(where: { $0.id == reservationId }) else {
            throw OfflineStorageLedgerError.missingReservation
        }
        var overflowReservationId: String?
        if asset.byteCount > reservation.byteCount {
            // Ad-inserting podcast hosts can serve a longer file than the HEAD request reported. Reserve the
            // difference under the same budget and eviction rules; only an overrun that doesn't fit is an error.
            do {
                overflowReservationId = try reserve(
                    ownerId: reservation.ownerId + ":overflow",
                    byteCount: asset.byteCount - reservation.byteCount
                ).id
            } catch OfflineStorageLedgerError.insufficientSpace {
                throw OfflineStorageLedgerError.reservationExceeded(
                    reservedBytes: reservation.byteCount,
                    actualBytes: asset.byteCount
                )
            }
        }
        try repository.saveOwnedOfflineAsset(asset)
        try repository.deleteOfflineStorageReservation(id: reservationId)
        pinnedPaths[reservationId] = nil
        if let overflowReservationId { try repository.deleteOfflineStorageReservation(id: overflowReservationId) }
    }

    public func release(reservationId: String) throws {
        try repository.deleteOfflineStorageReservation(id: reservationId)
        pinnedPaths[reservationId] = nil
    }

    public func protect(assetId: String, reason: OfflineProtectionReason, enabled: Bool) throws {
        try repository.updateOwnedOfflineAsset(id: assetId) { asset in
            if enabled { asset.protections.insert(reason) } else { asset.protections.remove(reason) }
        }
    }

    public func categoryUsage() throws -> [OfflineAssetCategory: Int64] {
        Dictionary(grouping: try repository.loadOwnedOfflineAssets(), by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.byteCount } }
    }

    public func presentationSnapshot(now: Date = Date()) throws -> OfflineStorageSnapshot {
        OfflineStorageSnapshot.make(
            budget: try repository.loadOfflineStorageBudget(),
            assets: try repository.loadOwnedOfflineAssets(),
            reservations: try repository.loadOfflineStorageReservations(),
            now: now
        )
    }

    public func clearReproducibleAssets(in categories: Set<OfflineAssetCategory>) throws -> Int64 {
        let assets = try repository.loadOwnedOfflineAssets()
        var removed: Int64 = 0
        var references = PreparedNarrationFallback.FileReferences(items: try repository.listItems(includeDeleted: true))
        for asset in assets where categories.contains(asset.category) && asset.isAutomaticallyEvictable {
            let url = rootDirectory.appending(path: asset.relativePath)
            guard try releaseReferences(to: url, references: &references) else { continue }
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try repository.deleteOwnedOfflineAsset(id: asset.id)
            removed += asset.byteCount
        }
        return removed
    }

    /// A render can finish after an extraction upgrade. Save its ledger row only with a live manifest.
    @discardableResult
    public func commitPrepared(reservationId: String, asset: OwnedOfflineAsset, manifest: PreparedAudioManifest) throws -> Bool {
        let saved = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: repository) { _, _ in
            try commit(reservationId: reservationId, asset: asset)
            return true
        } ?? false
        if !saved {
            try release(reservationId: reservationId)
            _ = try discardUncommittedFile(rootDirectory.appending(path: asset.relativePath))
        }
        return saved
    }

    /// Deletes one item's prepared audio (assembled narration and chunks) and their ledger
    /// rows, and nothing else: no recordings, Margins or other items' files. Used after the
    /// item moved to a new PDF extraction, so its audio no longer matches its text (#322).
    ///
    /// A file any item still plays stays, with its row (#344). Unlike eviction, nothing is
    /// detached: another item's narration still matches its own text.
    public func removePreparedAudio(itemId: String) throws -> Int64 {
        var removed: Int64 = 0
        let references = PreparedNarrationFallback.FileReferences(items: try repository.listItems(includeDeleted: true))
        for asset in try repository.loadOwnedOfflineAssets()
        where asset.itemId == itemId && (asset.category == .preparedAudio || asset.category == .preparedChunk) {
            guard try removeFileNoItemPlays(rootDirectory.appending(path: asset.relativePath), references: references) else { continue }
            try repository.deleteOwnedOfflineAsset(id: asset.id)
            removed += asset.byteCount
        }
        return removed
    }

    /// After an item moved to a new PDF extraction (#322): once its manifests are retired, its
    /// prepared files and rows go. An item that still has a manifest, or never had audio, keeps all.
    @discardableResult
    public func removeRetiredPreparedAudio(itemId: String) async -> Int64 {
        guard let store = repository as? any SessionRepositoryTransaction else { return 0 }
        return (try? store.withSessionTransaction {
            guard try repository.loadPreparedAudioManifests(itemId: itemId).isEmpty else { return Int64(0) }
            return try removePreparedAudio(itemId: itemId)
        }) ?? 0
    }

    /// Narration assembled for text its item no longer has (#344): the file goes unless an item
    /// plays it, and its reservation is released.
    public func discardStaleAssembly(_ url: URL?, reservationId: String) async {
        if let url, url.isFileURL { _ = try? discardUncommittedFile(url) }
        try? release(reservationId: reservationId)
    }

    /// Deletes a prepared file nothing was committed for, such as narration assembled
    /// for text its item no longer has, unless an item plays it (#344).
    @discardableResult
    public func discardUncommittedFile(_ url: URL) throws -> Bool {
        try removeFileNoItemPlays(url, references: PreparedNarrationFallback.FileReferences(items: try repository.listItems(includeDeleted: true)))
    }

    private func removeFileNoItemPlays(_ url: URL, references: PreparedNarrationFallback.FileReferences) throws -> Bool {
        guard references.release(url) == .unreferenced else { return false }
        // Another preparation can refer to a chunk or an artifact even before its item plays it.
        for asset in try repository.loadOwnedOfflineAssets() where !asset.isReproducible {
            if rootDirectory.appending(path: asset.relativePath).standardizedFileURL == url.standardizedFileURL { return false }
        }
        for item in try repository.listItems(includeDeleted: true) {
            for manifest in try repository.loadPreparedAudioManifests(itemId: item.id) {
                let paths = manifest.chunks.map { "PreparedAudio/\($0.relativePath)" }
                    + [manifest.artifact?.relativePath, manifest.artifact.map { "PreparedAudio/\($0.relativePath)" },
                       manifest.artifact.map { "PreparedSupertonicAudio/\($0.relativePath)" }].compactMap { $0 }
                if paths.contains(where: { rootDirectory.appending(path: $0).standardizedFileURL == url.standardizedFileURL }) { return false }
            }
        }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        return true
    }

    /// Settings > Storage > Clear Audio. The rendered speech cache is outside the ledger (#313), so it's
    /// cleared through the app's cache, under its lock, or by directory when this launch hasn't opened it.
    public func clearReproducibleAudio(renderedSpeechCache: (any RenderedSpeechCacheClearing)?) throws -> Int64 {
        let cleared = try clearReproducibleAssets(in: [.preparedAudio, .preparedChunk, .podcast, .guidedTour])
        let cacheDirectory = rootDirectory.appending(
            path: OfflineLedgerScope.renderedSpeechCacheDirectory, directoryHint: .isDirectory
        )
        let renderedBytes = renderedSpeechCache?.removeAll()
            ?? RenderedSpeechCacheFiles.removeAll(in: cacheDirectory, fileManager: fileManager)
        return cleared + renderedBytes
    }

    public func inventoryBytes() throws -> Int64 {
        try repository.loadOwnedOfflineAssets().reduce(0) { $0 + $1.byteCount }
    }

    /// Enforces a newly lowered or migrated budget immediately. Imported and
    /// recorded user assets remain non-evictable; the returned value is any
    /// residual overage that cannot be reclaimed safely.
    public func enforceBudget(now: Date = Date()) throws -> Int64 {
        try reconcileWithDisk()
        let budget = try repository.loadOfflineStorageBudget()
        let assets = try repository.loadOwnedOfflineAssets()
        let reservations = try repository.loadOfflineStorageReservations()
        let used = OfflineStoragePlanner.usageBytes(assets: assets, reservations: reservations, now: now)
        let deficit = max(0, used - budget.limitBytes)
        guard deficit > 0 else { return 0 }
        var (plan, references) = try evictionPlan(requiredBytes: deficit, assets: assets)
        let reclaimed = try execute(plan: plan, assets: assets, references: &references)
        return max(0, deficit - reclaimed)
    }

    /// Brings the rows in line with the disk (#259): rows for missing files are dropped, sizes come
    /// from disk, and rows naming one file become one. Never deletes a file.
    @discardableResult
    public func reconcileWithDisk() throws -> OfflineLedgerReconciliation {
        let recorded = try repository.loadOwnedOfflineAssets()
        let plan = OfflineLedgerReconciliation.plan(assets: recorded) { relative in
            let url = rootDirectory.appending(path: relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
            guard !isDirectory.boolValue,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .other }
            return .file(byteCount: Int64(size))
        }
        let recordedById = Dictionary(recorded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Another ledger on the same store can commit a new file under a dropped row's id meanwhile,
        // so a row is deleted only while it still names the file this reconcile checked (#530).
        for id in plan.removedAssetIds {
            guard let before = recordedById[id] else { continue }
            try repository.deleteOwnedOfflineAsset(id: id) { $0.relativePath == before.relativePath }
        }
        // The app toggles protections on these rows outside this actor while the files are checked,
        // so each row is re-read and only the plan's own changes are written (#287).
        for planned in plan.updatedAssets {
            guard let before = recordedById[planned.id] else { continue }
            try repository.updateOwnedOfflineAsset(id: planned.id) {
                OfflineLedgerReconciliation.apply(recorded: before, planned: planned, to: &$0)
            }
        }
        lastReconciliation = plan
        return plan
    }

    public func directFilesystemBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    public func trackedFilesystemBytes() throws -> Int64 {
        try repository.loadOwnedOfflineAssets().reduce(Int64(0)) { total, asset in
            let url = rootDirectory.appending(path: asset.relativePath)
            let size = (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))
            guard size?.isRegularFile == true else { return total }
            return total + Int64(size?.fileSize ?? 0)
        }
    }

    /// Enrols files older builds wrote without a row. The rendered speech cache isn't one of these
    /// directories: it manages its own size (#313, `OfflineLedgerScope`).
    public func adoptExistingAssets() throws {
        let directories: [(String, OfflineAssetCategory, Bool, Set<OfflineProtectionReason>)] = [
            ("PodcastAudio", .podcast, true, []),
            ("PreparedSupertonicAudio", .preparedAudio, true, []),
            ("PreparedAudio", .preparedAudio, true, []),
            ("Interjections", .interjection, false, [.interjection]),
            ("Audiobooks", .audiobook, false, [.importedAudiobook]),
            ("GuidedOnboarding", .guidedTour, true, []),
            ("WatchPackages", .dormantWatchPackage, false, [.dormantWatchTransfer])
        ]
        // Older builds could record the same physical file under more than one
        // ledger identifier. Adoption only needs path membership, and must remain
        // recoverable when those historical duplicates are present.
        let existingPaths = Set(try repository.loadOwnedOfflineAssets().map(\.relativePath))
        for (name, category, reproducible, protections) in directories {
            let directory = rootDirectory.appending(path: name, directoryHint: .isDirectory)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let relative = relativePath(url)
                if existingPaths.contains(relative) { continue }
                try repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
                    id: "adopted-\(Self.digest(relative))",
                    category: category,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0),
                    isReproducible: reproducible,
                    protections: protections,
                    lastAccessedAt: values.contentModificationDate ?? .distantPast,
                    createdAt: values.contentModificationDate ?? Date()
                ))
            }
        }
        if let currentPreparedChunkDigest {
            try markSupersededPreparedChunks(currentSignatureDigest: currentPreparedChunkDigest)
        }
    }

    /// After a change of voice, speed or chunking (Build 30 re-keyed every chunk, #240), prepared
    /// chunk files from the old signature are never read again. They're marked stale so they're
    /// the first to go when space is needed (#281); switching back makes them valid again. Never
    /// deletes a file. Returns how many rows changed.
    @discardableResult
    public func markSupersededPreparedChunks(currentSignatureDigest: String) throws -> Int {
        currentPreparedChunkDigest = currentSignatureDigest
        let changed = OfflineStoragePlanner.preparedChunkStaleness(
            assets: try repository.loadOwnedOfflineAssets(),
            currentSignatureDigest: currentSignatureDigest
        )
        for asset in changed { try repository.saveOwnedOfflineAsset(asset) }
        return changed.count
    }

    /// Eviction never leaves an item pointing at a deleted file (#237), so a file an item plays as
    /// its only audio isn't a candidate. Nor is a file a held reservation pins (#645).
    private func evictionPlan(
        requiredBytes: Int64, assets: [OwnedOfflineAsset], alsoPinning: Set<String> = []
    ) throws -> (OfflineEvictionPlan, PreparedNarrationFallback.FileReferences) {
        let references = PreparedNarrationFallback.FileReferences(items: try repository.listItems(includeDeleted: true))
        let pinned = pinnedPaths.values.reduce(alsoPinning) { $0.union($1) }
        let candidates = assets.filter { asset in
            !pinned.contains(asset.relativePath) && (
                !asset.isAutomaticallyEvictable
                    || references.release(rootDirectory.appending(path: asset.relativePath)) != .keep
            )
        }
        return (OfflineStoragePlanner.evictionPlan(requiredBytes: requiredBytes, assets: candidates), references)
    }

    /// Returns the bytes it actually freed, which is less than the plan's when a row was skipped.
    private func execute(
        plan: OfflineEvictionPlan,
        assets: [OwnedOfflineAsset],
        references: inout PreparedNarrationFallback.FileReferences
    ) throws -> Int64 {
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var reclaimed: Int64 = 0
        for id in plan.selectedAssetIds {
            guard let asset = byId[id], asset.isAutomaticallyEvictable else { continue }
            let url = rootDirectory.appending(path: asset.relativePath)
            guard try releaseReferences(to: url, references: &references) else { continue }
            let hasFile = fileManager.fileExists(atPath: url.path)
            // `assets` is an earlier read, and the app protects rows from the main actor meanwhile
            // (an episode starts playing). The row is judged as it is now, and its file is removed
            // inside the same store step (#530). A protection saved first keeps both; playback that
            // starts after finds no row and no file, never a URL about to vanish. A file that can't
            // be removed keeps its row, so its bytes stay charged and the shortfall refuses the
            // reservation.
            let deleted = try repository.deleteOwnedOfflineAsset(id: id, if: { current in
                guard current.isAutomaticallyEvictable, current.relativePath == asset.relativePath else { return false }
                guard hasFile, fileManager.fileExists(atPath: url.path) else { return true }
                return (try? fileManager.removeItem(at: url)) != nil
            })
            guard deleted else { continue }
            reclaimed += asset.byteCount
        }
        return reclaimed
    }

    /// Items that play `url` as generated narration are detached before it's deleted, and read
    /// their text live until it's rendered again. False when another item plays it.
    ///
    /// The index is a snapshot, and the app saves items from the main actor while this actor
    /// evicts. So each item is re-read just before it's saved: only its media changes, and only
    /// if it still plays `url`, so an edit made since the snapshot isn't overwritten.
    private func releaseReferences(
        to url: URL, references: inout PreparedNarrationFallback.FileReferences
    ) throws -> Bool {
        let decision = references.release(url)
        guard case .detach(let candidates) = decision else { return decision == .unreferenced }
        for candidate in candidates {
            let current = try repository.loadItem(id: candidate.id)
            switch PreparedNarrationFallback.release(url, from: [current]) {
            case .unreferenced:
                continue
            case .keep:
                return false
            case .detach(let detached):
                for item in detached {
                    try repository.saveItem(item)
                    try PreparedNarrationFallback.markPreparedAudioForRepreparation(itemId: item.id, repository: repository)
                }
            }
        }
        references.forget(url)
        return true
    }

    /// What the volume can still hold for the listener's own files. Unknown off Apple platforms, where the
    /// budget alone limits a reservation.
    private func physicallyAvailableBytes() -> Int64? {
        #if canImport(Darwin)
        try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        #else
        nil
        #endif
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootDirectory.path + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootDirectory.path.count + 1))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
