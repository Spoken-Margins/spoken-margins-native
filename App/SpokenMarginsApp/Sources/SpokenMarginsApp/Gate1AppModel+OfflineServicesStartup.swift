import Foundation
import SessionKit
import SessionKitPersistence

/// The startup work each store configuration runs: save the storage budget, adopt and trim offline files, then
/// refresh Following and the guided tour. Moved out of the central model for #2195.
extension Gate1AppModel {
    /// Holds the model weakly and stops when the model goes away. It used to hold the model strongly, so a dropped
    /// model lived on until the tour download ended, and its SQLite calls then ran on the main thread during
    /// whatever came next. Against another connection to the same file each one could wait out the store's 1 s
    /// busy timeout (#2195).
    func startOfflineServices(store: SQLiteSessionStore, ledger: OfflineStorageLedger) {
        offlineServicesStartupTasks.append(Task { [weak self] in
            guard let limitGB = self?.offlineStorageLimitGB, !Task.isCancelled else { return }
            try? store.saveOfflineStorageBudget(OfflineStorageBudget(
                limitBytes: Int64(limitGB) * OfflineStorageBudget.bytesPerGigabyte
            ))
            try? await ledger.adoptExistingAssets()
            guard !Task.isCancelled else { return }
            let residualOverage = try? await ledger.enforceBudget()
            let reconciled = await ledger.lastReconciliation?.summary ?? "failed"
            let ledgerBytes = try? await ledger.inventoryBytes()
            let filesystemBytes = await ledger.directFilesystemBytes()
            guard let self, !Task.isCancelled else { return }
            diagnostics["offlineLedgerReconciled"] = reconciled
            diagnostics["offlineLedgerBytes"] = "\(ledgerBytes ?? 0)"
            diagnostics["offlineFilesystemBytes"] = "\(filesystemBytes)"
            diagnostics["offlineResidualOverageBytes"] = "\(residualOverage ?? 0)"
            tryRefreshOfflineStorageUsage()
            await performFollowedSourceRefresh(force: false)
            guard !Task.isCancelled else { return }
            await refreshGuidedOnboardingContent()
        })
    }
}
