import Foundation

/// #259: the offline ledger charged about 1.15 GB of files that no longer existed, because several
/// paths delete files without telling it, adoption only ever adds rows, and more than one row can
/// name the same file. Phantom charges can make eviction pick real narration or podcasts first, or
/// refuse a download with plenty of disk free.
///
/// Reconciliation brings the rows back in line with the disk, whatever deleted the file:
/// - a row whose file is gone is dropped (only the row: this never deletes a file);
/// - a row whose file changed size takes the size on disk;
/// - rows naming the same file become one, keeping every protection.
public struct OfflineLedgerReconciliation: Equatable, Sendable {
    /// What's at a row's path now.
    public enum PathState: Equatable, Sendable {
        case missing
        case file(byteCount: Int64)
        /// A directory or an unreadable entry: rows at this path are left as they are.
        case other
    }

    public private(set) var removedAssetIds: [String] = []
    public private(set) var updatedAssets: [OwnedOfflineAsset] = []
    public private(set) var missingRowCount = 0
    public private(set) var resizedRowCount = 0
    public private(set) var mergedRowCount = 0
    /// Recorded bytes minus reconciled bytes: what the ledger stops charging.
    public private(set) var bytesNoLongerCharged: Int64 = 0

    public init() {}

    public var isEmpty: Bool { removedAssetIds.isEmpty && updatedAssets.isEmpty }

    /// One line for diagnostics.
    public var summary: String {
        "missing=\(missingRowCount) resized=\(resizedRowCount) merged=\(mergedRowCount) bytes=\(bytesNoLongerCharged)"
    }

    public static func plan(assets: [OwnedOfflineAsset], pathState: (String) -> PathState) -> OfflineLedgerReconciliation {
        var result = OfflineLedgerReconciliation()
        let byPath = Dictionary(grouping: assets, by: \.relativePath)
        for path in byPath.keys.sorted() {
            guard let rows = byPath[path] else { continue }
            let recorded = rows.reduce(Int64(0)) { $0 + $1.byteCount }
            switch pathState(path) {
            case .other:
                continue
            case .missing:
                result.removedAssetIds += rows.map(\.id)
                result.missingRowCount += rows.count
                result.bytesNoLongerCharged += recorded
            case .file(let byteCount):
                let ordered = rows.sorted(by: keeperFirst)
                var keeper = ordered[0]
                let aliases = ordered.dropFirst()
                let original = keeper
                for alias in aliases {
                    keeper.protections.formUnion(alias.protections)
                    keeper.isReproducible = keeper.isReproducible && alias.isReproducible
                    keeper.itemId = keeper.itemId ?? alias.itemId
                    keeper.lastAccessedAt = max(keeper.lastAccessedAt, alias.lastAccessedAt)
                    keeper.createdAt = min(keeper.createdAt, alias.createdAt)
                }
                if keeper.byteCount != byteCount {
                    keeper.byteCount = byteCount
                    keeper.checksumSHA256 = nil // it described the old contents
                    result.resizedRowCount += 1
                }
                if !aliases.isEmpty {
                    result.removedAssetIds += aliases.map(\.id)
                    result.mergedRowCount += aliases.count
                }
                if keeper != original { result.updatedAssets.append(keeper) }
                result.bytesNoLongerCharged += recorded - byteCount
            }
        }
        result.removedAssetIds.sort()
        return result
    }

    /// Among rows naming one file, the writer's own row wins over an adopted one (adoption only
    /// guesses the category and has no owner); then the one with an owner; then the oldest.
    private static func keeperFirst(_ lhs: OwnedOfflineAsset, _ rhs: OwnedOfflineAsset) -> Bool {
        let lhsAdopted = lhs.id.hasPrefix("adopted-")
        let rhsAdopted = rhs.id.hasPrefix("adopted-")
        if lhsAdopted != rhsAdopted { return !lhsAdopted }
        if (lhs.itemId != nil) != (rhs.itemId != nil) { return lhs.itemId != nil }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}
