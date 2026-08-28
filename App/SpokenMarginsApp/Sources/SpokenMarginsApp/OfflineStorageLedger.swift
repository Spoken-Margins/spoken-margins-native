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
        let assets = try repository.loadOwnedOfflineAssets()
        let reservations = try repository.loadOfflineStorageReservations()
        let used = OfflineStoragePlanner.usageBytes(assets: assets, reservations: reservations, now: now)
        let requested = max(0, byteCount)
        let deficit = max(0, used + requested - budget.limitBytes)
        if deficit > 0 {
            let plan = OfflineStoragePlanner.evictionPlan(requiredBytes: deficit, assets: assets)
            guard plan.reclaimableBytes >= deficit else {
                throw OfflineStorageLedgerError.insufficientSpace(
                    requiredBytes: requested,
                    availableBytes: max(0, budget.limitBytes - used + plan.reclaimableBytes)
                )
            }
            try execute(plan: plan, assets: assets)
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
        guard asset.byteCount <= reservation.byteCount else {
            throw OfflineStorageLedgerError.reservationExceeded(
                reservedBytes: reservation.byteCount,
                actualBytes: asset.byteCount
            )
        }
        try repository.saveOwnedOfflineAsset(asset)
        try repository.deleteOfflineStorageReservation(id: reservationId)
    }

    func release(reservationId: String) throws {
        try repository.deleteOfflineStorageReservation(id: reservationId)
    }

    func protect(assetId: String, reason: OfflineProtectionReason, enabled: Bool) throws {
        guard var asset = try repository.loadOwnedOfflineAssets().first(where: { $0.id == assetId }) else { return }
        if enabled { asset.protections.insert(reason) } else { asset.protections.remove(reason) }
        try repository.saveOwnedOfflineAsset(asset)
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
        for asset in assets where categories.contains(asset.category) && asset.isAutomaticallyEvictable {
            let url = rootDirectory.appending(path: asset.relativePath)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try repository.deleteOwnedOfflineAsset(id: asset.id)
            removed += asset.byteCount
        }
        return removed
    }

    func inventoryBytes() throws -> Int64 {
        try repository.loadOwnedOfflineAssets().reduce(0) { $0 + $1.byteCount }
    }

    /// Enforces a newly lowered or migrated budget immediately. Imported and
    /// recorded user assets remain non-evictable; the returned value is any
    /// residual overage that cannot be reclaimed safely.
    func enforceBudget(now: Date = Date()) throws -> Int64 {
        let budget = try repository.loadOfflineStorageBudget()
        let assets = try repository.loadOwnedOfflineAssets()
        let reservations = try repository.loadOfflineStorageReservations()
        let used = OfflineStoragePlanner.usageBytes(assets: assets, reservations: reservations, now: now)
        let deficit = max(0, used - budget.limitBytes)
        guard deficit > 0 else { return 0 }
        let plan = OfflineStoragePlanner.evictionPlan(requiredBytes: deficit, assets: assets)
        try execute(plan: plan, assets: assets)
        return max(0, deficit - plan.reclaimableBytes)
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

    func adoptExistingAssets() throws {
        let directories: [(String, OfflineAssetCategory, Bool, Set<OfflineProtectionReason>)] = [
            ("PodcastAudio", .podcast, true, []),
            ("RenderedSpeechCache", .preparedChunk, true, []),
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

    private func execute(plan: OfflineEvictionPlan, assets: [OwnedOfflineAsset]) throws {
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for id in plan.selectedAssetIds {
            guard let asset = byId[id], asset.isAutomaticallyEvictable else { continue }
            let url = rootDirectory.appending(path: asset.relativePath)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try repository.deleteOwnedOfflineAsset(id: id)
        }
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
