import CryptoKit
import Foundation
import SessionKit

enum OfflineStorageLedgerError: Error, LocalizedError, Equatable {
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case missingReservation
    case reservationExceeded(reservedBytes: Int64, actualBytes: Int64)

    var errorDescription: String? {
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

actor OfflineStorageLedger {
    private let repository: any SessionRepository
    private let rootDirectory: URL
    private let fileManager: FileManager
    /// The last reconciliation's counts, for diagnostics (#259).
    private(set) var lastReconciliation: OfflineLedgerReconciliation?

    init(repository: any SessionRepository, rootDirectory: URL, fileManager: FileManager = .default) {
        self.repository = repository
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func reserve(ownerId: String, byteCount: Int64, lifetime: TimeInterval = 60 * 60) throws -> OfflineStorageReservation {
        let now = Date()
        for expired in try repository.loadOfflineStorageReservations() where expired.expiresAt <= now {
            try repository.deleteOfflineStorageReservation(id: expired.id)
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
            var (plan, references) = try evictionPlan(requiredBytes: deficit, assets: assets)
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
        if let physicalAvailable = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
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
        return reservation
    }

    func commit(reservationId: String, asset: OwnedOfflineAsset) throws {
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
        if let overflowReservationId { try repository.deleteOfflineStorageReservation(id: overflowReservationId) }
    }

    func release(reservationId: String) throws {
        try repository.deleteOfflineStorageReservation(id: reservationId)
    }

    func protect(assetId: String, reason: OfflineProtectionReason, enabled: Bool) throws {
        try repository.updateOwnedOfflineAsset(id: assetId) { asset in
            if enabled { asset.protections.insert(reason) } else { asset.protections.remove(reason) }
        }
    }

    func categoryUsage() throws -> [OfflineAssetCategory: Int64] {
        Dictionary(grouping: try repository.loadOwnedOfflineAssets(), by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.byteCount } }
    }

    func presentationSnapshot(now: Date = Date()) throws -> OfflineStorageSnapshot {
        OfflineStorageSnapshot.make(
            budget: try repository.loadOfflineStorageBudget(),
            assets: try repository.loadOwnedOfflineAssets(),
            reservations: try repository.loadOfflineStorageReservations(),
            now: now
        )
    }

    func clearReproducibleAssets(in categories: Set<OfflineAssetCategory>) throws -> Int64 {
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

    /// Settings > Storage > Clear Audio. The rendered speech cache is outside the ledger (#313), so it's
    /// cleared through the app's cache, under its lock, or by directory when this launch hasn't opened it.
    func clearReproducibleAudio(renderedSpeechCache: RenderedSpeechDiskCache?) throws -> Int64 {
        let cleared = try clearReproducibleAssets(in: [.preparedAudio, .preparedChunk, .podcast, .guidedTour])
        let cacheDirectory = rootDirectory.appending(
            path: OfflineLedgerScope.renderedSpeechCacheDirectory, directoryHint: .isDirectory
        )
        let renderedBytes = renderedSpeechCache?.removeAll()
            ?? RenderedSpeechDiskCache.removeAll(in: cacheDirectory, fileManager: fileManager)
        return cleared + renderedBytes
    }

    func inventoryBytes() throws -> Int64 {
        try repository.loadOwnedOfflineAssets().reduce(0) { $0 + $1.byteCount }
    }

    /// Enforces a newly lowered or migrated budget immediately. Imported and
    /// recorded user assets remain non-evictable; the returned value is any
    /// residual overage that cannot be reclaimed safely.
    func enforceBudget(now: Date = Date()) throws -> Int64 {
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
    func reconcileWithDisk() throws -> OfflineLedgerReconciliation {
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

    func directFilesystemBytes() -> Int64 {
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

    func trackedFilesystemBytes() throws -> Int64 {
        try repository.loadOwnedOfflineAssets().reduce(Int64(0)) { total, asset in
            let url = rootDirectory.appending(path: asset.relativePath)
            let size = (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))
            guard size?.isRegularFile == true else { return total }
            return total + Int64(size?.fileSize ?? 0)
        }
    }

    /// Enrols files older builds wrote without a row. The rendered speech cache isn't one of these
    /// directories: it manages its own size (#313, `OfflineLedgerScope`).
    func adoptExistingAssets() throws {
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
    }

    /// Eviction never leaves an item pointing at a deleted file (#237), so a file an item plays as
    /// its only audio isn't a candidate.
    private func evictionPlan(
        requiredBytes: Int64, assets: [OwnedOfflineAsset]
    ) throws -> (OfflineEvictionPlan, PreparedNarrationFallback.FileReferences) {
        let references = PreparedNarrationFallback.FileReferences(items: try repository.listItems(includeDeleted: true))
        let candidates = assets.filter { asset in
            !asset.isAutomaticallyEvictable
                || references.release(rootDirectory.appending(path: asset.relativePath)) != .keep
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
            // (an episode starts playing). The row is judged as it is now and deleted in the same
            // step, before its file, so a protected file is never deleted (#530).
            guard try repository.deleteOwnedOfflineAsset(id: id, if: {
                $0.isAutomaticallyEvictable && $0.relativePath == asset.relativePath
            }) else { continue }
            if hasFile { try fileManager.removeItem(at: url) }
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

    private func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootDirectory.path + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootDirectory.path.count + 1))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
